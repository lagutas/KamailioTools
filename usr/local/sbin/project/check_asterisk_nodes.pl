#!/usr/bin/perl 

#lagutas 21.06.2013 скрипт мониторинга нод asterisk
#мониторит таблицу dispatcher при обнаружении status отличного от 1 выводит из балансировки ноду asterisk
#при обнаружении 1 вводит
#если не может сделать тестовую регистрацию то делает status 2 и выводит

use strict;
use Net::SIP;
use Sys::Hostname;
use DBI();
use POSIX qw(strftime);

use Logic::Tools;

# Задаем pid файл и пользователя из под которого запускаем демона
my $lock_file = '/var/run/check_asterisk_nodes.pid';
my $runas_user = 'root';

my $tools=Logic::Tools->new(config_file =>  '/etc/project/check-asterisk-nodes.ini',
                            lock_file   =>  $lock_file,
                            runas_user  =>  $runas_user,
                            logfile     =>  '/var/log/project/check_asterisk_nodes.log',
                            logsize     =>  '100Mb',
                            log_num     =>  4);

my $db_host=$tools->read_config( 'check_asterisk_nodes', 'db_host');
my $db=$tools->read_config( 'check_asterisk_nodes', 'db');
my $dispatcher_table=$tools->read_config( 'check_asterisk_nodes', 'dispatcher_table');
my $db_user=$tools->read_config( 'check_asterisk_nodes', 'db_user');
my $db_password=$tools->read_config( 'check_asterisk_nodes', 'db_password');
my $my_host=$tools->read_config('check_asterisk_nodes','my_host');
my $sip_port=$tools->read_config('check_asterisk_nodes','sip_port');
my $sip_user=$tools->read_config('check_asterisk_nodes','sip_user');
my $sip_secret=$tools->read_config('check_asterisk_nodes','sip_secret');
my $setids=$tools->read_config('check_asterisk_nodes','setid');
my $dispatcher_reload=$tools->read_config('check_asterisk_nodes','dispatcher_reload');
my $timeout=$tools->read_config('check_asterisk_nodes','timeout');




################### задаём запросы для БД ##############################
my %query;
# get_asterisk_nodes - возвращает asterisk ноды заданной группы setid_previous
$query{'get_asterisk_nodes'} = <<EOQ;
SELECT
    setid,
    setid_previous,
    status,
    description,
    destination
FROM
    $db.$dispatcher_table
WHERE
    setid_previous=?;
EOQ

# asterisk_disable - выводиv asterisk ноду из балансировки
$query{'asterisk_disable'} = <<EOQ;
UPDATE $db.$dispatcher_table SET setid = 0 WHERE description=? and setid_previous=?;
EOQ

# asterisk_set_disable_status - меняем статус на 2, т.к. с asterisk-ом что-то не то
$query{'asterisk_set_disable_status'} = <<EOQ;
UPDATE $db.$dispatcher_table SET status=2 WHERE description=? and setid_previous=?;
EOQ

# asterisk_enable - вводим в балансировку, меняем setid на установленный по умолчанию setid_previous
$query{'asterisk_enable'} = <<EOQ;
UPDATE $db.$dispatcher_table SET setid = setid_previous WHERE description=? and setid_previous=?;
EOQ

$query{'asterisk_set_enable_status'} = <<EOQ;
UPDATE $db.$dispatcher_table SET status=1 WHERE description=? and setid_previous=?;
EOQ

#проверка не запущен ли этот процесс
$tools->check_proc();

#запускаем как демон
$tools->supervisor_start_daemon();

my $dbh;
eval 
{
    $dbh=DBI->connect("DBI:mysql:$db;host=$db_host",$db_user,$db_password);
};
if ($@) 
{
    die "Error: не удается подключиться к базе данных $db $db_host $db_user $DBI::errstr\n";
}
$dbh->{mysql_auto_reconnect} = 1;

$tools->logprint("info","вход в цикл");


while(1)
{
    foreach(split(/,/,$setids))
    {
        my $setid=$_;
        my $asterisk_nodes=get_asterisk_param($setid);
    
        $tools->logprint("info","================== начинаем проверочный цикл=====================");
        
        foreach my $key (keys   %$asterisk_nodes)
        {
            $tools->logprint("info","setid $key - $$asterisk_nodes{$key}->{SETID}");
            $tools->logprint("info","setid_previous $key - $$asterisk_nodes{$key}->{SETID_PREVIOUS}");
            $tools->logprint("info","status $key - $$asterisk_nodes{$key}->{STATUS}");

            if($$asterisk_nodes{$key}->{SETID}==$$asterisk_nodes{$key}->{SETID_PREVIOUS})
            {
                $tools->logprint("info","$key в балансировке");
                if($$asterisk_nodes{$key}->{STATUS}==0||$$asterisk_nodes{$key}->{STATUS}==2)
                {
                    $tools->logprint("info","выводим $key из балансировки");
                    $tools->logprint("warning","выводим $key из балансировки $key $setid");
                    #выводим
                    eval 
                    {
                        $dbh->do($query{'asterisk_disable'},undef,$key,$setid);
                    };
                    if ($@) 
                    {
                        $tools->logprint("error","ошибка выполнения запроса $query{'asterisk_disable'},$key,$setid : $DBI::errstr");
                    }
                    

                    $tools->logprint("info","выполняем команду $dispatcher_reload");
                    my $result;
                    eval 
                    {
                        $result=`$dispatcher_reload`;
                        $tools->logprint("info","результа выполнения $result");
                    };
                    if ($@) 
                    {
                        $tools->logprint("error","что-то пошло не так $!");
                    }
                    
                    
                }

                #проверяем регистрацию и выводим из балансировки по необходимости
                my $status=check_register($my_host,$sip_port,$sip_user,$sip_secret,$$asterisk_nodes{$key}->{DESTINATION});
                $tools->logprint("info","статус регистрации = $status");

                if(!defined($status))
                {
                    $tools->logprint("warning","регистрация неуспешна, необходимо вывести $key из балансировки");
                    eval 
                    {
                        $dbh->do($query{'asterisk_set_disable_status'},undef,$key,$setid);
                    };
                    if ($@) 
                    {
                        $tools->logprint("error","ошибка выполнения запроса $query{'asterisk_set_disable_status'},$key,$setid : $DBI::errstr"); 
                    }
                }
            }
            else
            {
                if($$asterisk_nodes{$key}->{STATUS}==1)
                {
                    $tools->logprint("warning","вводим $key в балансировку");
                    #вводим
                    $dbh->do($query{'asterisk_enable'},undef,$key,$setid);
                    $tools->logprint("info","выполняем команду $dispatcher_reload");
                    sleep(1);
                    my $result=`$dispatcher_reload`;
                    $tools->logprint("info","результа выполнения $result");
                }

                #проверяем регистрацию и вводим в балансировки по необходимости
                my $status=check_register($my_host,$sip_port,$sip_user,$sip_secret,$$asterisk_nodes{$key}->{DESTINATION});
                $tools->logprint("info","статус регистрации = $status");

                if(defined($status)&&$$asterisk_nodes{$key}->{STATUS}==2)
                {
                    $tools->logprint("debug","регистрация успешна, необходимо ввести $key в балансировку");
                    
                    eval 
                    {
                        $dbh->do($query{'asterisk_set_enable_status'},undef,$key,$setid);
                    };
                    if ($@) 
                    {
                        $tools->logprint("error","ошибка выполнения запроса $query{'asterisk_set_enable_status'},$key,$setid : $DBI::errstr");
                    }
                }


            }
        }   
    }
    

    $tools->logprint("info","\n\n\n");
    sleep($timeout);
}



sub check_register
{
    my $my_host = shift;
    my $port = shift;
    my $hostname=hostname;
    my $user=shift;
    my $secret=shift;

    my $host=shift;
    $host=~s/^sip:(.+):\d+$/$1/;

    my $ua = Net::SIP::Simple->new( outgoing_proxy => $host,
                                    registrar => $host,
                                    domain => $hostname,
                                    from => $user,
                                    auth => [ $user, $secret ],
                                    leg => $my_host.':'.$port
                                    );
    my $status = $ua->register;
    my $error = $ua->error();

    $ua->cleanup;   

    return $status;
}


sub get_asterisk_param
{
    my $setid=shift;

    my %asterisk_nodes;

    my $asterisk_nodes_request=$dbh->prepare($query{'get_asterisk_nodes'});

    #$asterisk_nodes_request->execute();
    eval 
    {
        $asterisk_nodes_request->execute($setid);
    };
    if ($@) 
    {
        $tools->logprint("error","ошибка выполнения запроса $query{'get_asterisk_nodes'} : $DBI::errstr");
    }
    

    #получаем настройки
    while(my $ref=$asterisk_nodes_request->fetchrow_hashref())
    {
        $asterisk_nodes{$ref->{description}}->{SETID}=$ref->{setid};
        $asterisk_nodes{$ref->{description}}->{SETID_PREVIOUS}=$ref->{setid_previous};
        $asterisk_nodes{$ref->{description}}->{STATUS}=$ref->{status};
        $asterisk_nodes{$ref->{description}}->{DESTINATION}=$ref->{destination};
        
    }
    $asterisk_nodes_request->finish();

    return \%asterisk_nodes;
}