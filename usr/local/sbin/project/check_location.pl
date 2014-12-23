#!/usr/bin/perl

# Version 1.0
#скрипт для измререния времени ответа от SIP URI через kamailio, используется sipsak
#sipsak -> kamailio -> SIP URI -> kamailio -> check_location
#для корректной работы надо

#1. добавить правило обработки в kamailio 
#if(is_method("OPTIONS"))
#{
#       #!ifdef VERBOSE_LOG
#       xlog("L_INFO", "OPTIONS detect:M=$rm RURI=$ru F=$fu T=$tu IP=$si destination - $rd\n");
#       #!endif
#       if(from_uri=~"sip:sipsak@.+")
#       {
#               xlog("L_INFO", "OPTIONS from sipsak:M=$rm RURI=$ru F=$fu T=$tu IP=$si destination - $rd\n");
#               if (!lookup("location"))
#               {
#                   xlog("L_INFO", "OPTIONS to client, client not found:M=$rm RURI=$ru F=$fu T=$tu IP=$si destination - $rd\n");
#               }
#               route(RELAY);
#               exit;
#       }
#       options_reply();
#       exit;
#}
#2. создать config file /etc/project/check-location.ini:
#[check_locations]
#db_host            =   127.0.0.1
#db                 =   kamailio
#db_user            =   kamailio
#db_password        =   kamailiorw
##частота проверка SIP URI 
#check_timeout      =   30
#location_table =   location
#sipsak_path        =   /usr/bin/sipsak
#домен на который слать запросы
#kamailio_domain    =   sip.zadarma.com
#максимальное количество форков одновремеренно опрашивающих peer-ы
#fork_limit     =   50

#3. адаптировать таблицы для kamailio
#ALTER
#TABLE `kamailio`.`location` 
#ADD COLUMN `qualify_date` DATETIME NULL;

#ALTER
#TABLE `kamailio`.`location` 
#ADD COLUMN `qualify_time` INT(10) NULL;

#ALTER
#TABLE `kamailio`.`location` 
#ADD COLUMN `qualify_check` INT(1) NULL;

use strict;


$SIG{CHLD} = 'IGNORE';

use DBI();
use Time::HiRes qw(gettimeofday tv_interval);
use POSIX qw(strftime);
use POSIX;
use Term::ReadKey;

use Logic::Tools;


my $lock_file = '/var/run/check_location.pid';
my $runas_user = 'root';

my $tools=Logic::Tools->new(config_file =>  '/etc/project/check-location.ini',
                            lock_file   =>  $lock_file,
                            runas_user  =>  $runas_user,
                            logfile     =>  '/var/log/project/check_location.log',
                            logsize     =>  '100Mb',
                            log_num     =>  4);

my $db_host=$tools->read_config( 'check_locations', 'db_host');
my $db=$tools->read_config( 'check_locations', 'db');
my $db_user=$tools->read_config( 'check_locations', 'db_user');
my $db_password=$tools->read_config( 'check_locations', 'db_password');
my $location_table=$tools->read_config( 'check_locations', 'location_table');
my $check_timeout=$tools->read_config( 'check_locations', 'check_timeout');
my $sipsak_path=$tools->read_config( 'check_locations', 'sipsak_path');
my $kamailio_domain=$tools->read_config( 'check_locations', 'kamailio_domain');
my $fork_limit=$tools->read_config( 'check_locations', 'fork_limit');

#test sipsak
my @sipsak_test=split("\n",`$sipsak_path -V`);
if($sipsak_test[0]=~/^sipsak\s\d+\.\d+\.\d+.+$/)
{
    $tools->logprint("info","версия sipsak $sipsak_test[0]");
}
else
{
    $tools->logprint("error","sipsak не установлен");
    die "sipsak не установлен\n";
}


################### задаём запросы для БД ##############################
my %query;

#запрос на получение пиров
$query{'get_peers'} = <<EOF;
SELECT
    username
FROM
    $db.$location_table
WHERE
    (qualify_date<=? - INTERVAL ? second OR 
    qualify_date IS NULL) AND
    qualify_check IS NULL
ORDER BY qualify_date
LIMIT ?;
EOF

#запрос на выставление флага сигнализирующего о начале проверки пира
$query{'set_peers_qualify_check'} = <<EOF;
UPDATE
    $db.$location_table
SET
    qualify_check=1
WHERE
    username=?;
EOF

#запрос на выставление резултата измерений
$query{'set_measurement_result'} = <<EOF;
UPDATE
    $db.$location_table
SET
    qualify_check=NULL,
    qualify_date=Now(),
    qualify_time=?
WHERE
    username=?;
EOF


#запрос на получение пиров не обновлявшихся 5 интервалов подряд
$query{'get_freeze_measurement'} = <<EOF;
SELECT
    username
FROM
    $db.$location_table
WHERE
    qualify_check=1 AND
    (qualify_date<=? - INTERVAL ? SECOND) OR qualify_date is NULL;
EOF

#сброс замершего измерения
$query{'reset_freeze_measurement'} = <<EOF;
UPDATE
    $db.$location_table
SET
    qualify_check=NULL
WHERE
    username=?;
EOF

$tools->check_proc();
$tools->supervisor_start_daemon();
$tools->logprint("info","start check_location");
my $dbh;
eval 
{
    $dbh=DBI->connect("DBI:mysql:$db;host=$db_host",$db_user,$db_password) or die "Error: не удается подключиться к базе данных $db $db_host $db_user $!\n";
};
if ($@) 
{
    die "Error: не удается подключиться к базе данных $db $db_host $db_user $!\n";
}
$dbh->{mysql_auto_reconnect} = 1;

#пиды форков
my @forks_pid;

while(1)
{
    my ($sec, $min, $hour, $day, $mon, $year) = ( localtime(time) )[0,1,2,3,4,5];
    my $date=sprintf("%04d-%02d-%02d %02d:%02d:%02d",$year+1900,$mon+1,$day,$hour,$min,$sec);

    $tools->logprint("info","обновляем массив форков");
    decrement_old_forks();


    #$tools->logprint("info","$query{'get_peers'} -----------------1--------------------");
    #получение пиров для измерения
    my $sth;
    eval 
    {
        $sth=$dbh->prepare($query{'get_peers'});
    };
    if ($@) 
    {
        $tools->logprint("error","ошибка выполнения запроса $query{'get_peers'}: $!");
    }
    

    
    $sth->execute($date,$check_timeout,$fork_limit);
    #$sth->execute($check_timeout,$fork_limit);
    while(my $sip_peers_hash=$sth->fetchrow_hashref())
    {
        

        #если количество форков превышает заданный лимит
        my $num_of_fork=scalar(@forks_pid);
        if($num_of_fork>=$fork_limit)
        {
            $tools->logprint("info","допустимое количество форков превышено ($num_of_fork > $fork_limit)");

            #проверка живых пидов
            sleep(1);
            last;
        }
        else
        {
            #измерения проводим в форке, чтобы не блокировать работу если один из пиров станет недоступным
            my $subprocess_pid=fork;
            if($subprocess_pid == 0)
            {
                my $dbh_fork;
                eval 
                {
                    $dbh_fork=DBI->connect("DBI:mysql:$db;host=$db_host",$db_user,$db_password) or die "Error: не удается подключиться к базе данных $db $db_host $db_user $!\n";
                };
                if ($@) 
                {
                    $tools->logprint("error","ошибка подключения $DBI::errstr");               
                }
                $dbh_fork->{mysql_auto_reconnect} = 1;
                $tools->logprint("info","-------- $sip_peers_hash->{'username'} измерение задержки на OPTIONS запрос");
                #выставляем пометку пиру, что идет опрос пира
                eval 
                {
                    $dbh_fork->do($query{set_peers_qualify_check},undef,$sip_peers_hash->{'username'});
                };
                if ($@) 
                {
                    $tools->logprint("error","Error: ошибка выполнения запроса $query{'set_peers_qualify_check'}: $DBI::errstr");
                }
                
                

                my $start_time= [ gettimeofday ];
                my $sipsak="$sipsak_path -v -s sip:".$sip_peers_hash->{'username'}."@".$kamailio_domain;
                $tools->logprint("info","запрос $sipsak");
                
                my @options=`$sipsak`;
                my $end_time = [ gettimeofday ];
                my $answer = $options[0];
                my $elapsed = tv_interval($start_time,$end_time) * 1000; # возвращаем время в милисекундах
                if ($answer =~ m/.*200 OK.*/)
                {
                    $tools->logprint("info","результат измерения задержки на options запрос, пользователь: $sip_peers_hash->{'username'}, задержка: $elapsed");
                    eval 
                    {
                        $dbh_fork->do($query{set_measurement_result},undef,$elapsed,$sip_peers_hash->{'username'})
                    };
                    if ($@) 
                    {
                        $tools->logprint("error","Error: ошибка выполнения запроса $query{'set_measurement_result'}: $DBI::errstr");    
                    }
                }
                else
                {
                    $tools->logprint("info","пользователь: $sip_peers_hash->{'username'} не ответил");
                    eval 
                    {
                        $dbh_fork->do($query{set_measurement_result},undef,-1,$sip_peers_hash->{'username'});    
                    };
                    if ($@) 
                    {
                        $tools->logprint("error","Error: ошибка выполнения запроса $query{'set_measurement_result'}: $DBI::errstr");
                    }
                
                }
                $dbh_fork->disconnect();
                exit;
            }
            else
            {
                push(@forks_pid,$subprocess_pid);
            }
        }
    }
    $sth->finish();


    #$tools->logprint("info","$query{'get_peers'} -----------------2--------------------");

    

    #получение пиров, которые давно не обновлялись
    my $sth=$dbh->prepare($query{'get_freeze_measurement'});
    eval 
    {
        $sth->execute($date,$check_timeout*5);
    };
    if ($@) 
    {
        $tools->logprint("error","Error: ошибка выполнения запроса $query{'get_freeze_measurement'}: $DBI::errstr");
    }
    
    while(my $sip_peers_hash=$sth->fetchrow_hashref())
    {
        $tools->logprint("info","-------- $sip_peers_hash->{'username'} получен пир который давно не обновлялся, сбрасываю его");
        eval 
        {
            $dbh->do($query{reset_freeze_measurement},undef,$sip_peers_hash->{'username'});
        };
        if ($@) 
        {
            $tools->logprint("error","Error: ошибка выполнения запроса $query{'reset_freeze_measurement'}: $DBI::errstr"); 
        }
    }
    $sth->finish();
    
    sleep(1);
}


sub decrement_old_forks
{
    for(my $i=0;$i<=scalar(@forks_pid)-1;$i++)
    {
        if(!-e "/proc/$forks_pid[$i]")
        {
            $tools->logprint("info","форк $forks_pid[$i] завершил свою работу, удаляем его");
            #удаление пида форка из процессов
            splice(@forks_pid,$i,1)
        }
    }
}