#!/usr/bin/perl

#kamailio-tools.ini
#[repair_register]
#db_host            =   localhost
#db                 =   kamailio
#location_table     =   location
#db_user            =   kamailio
#db_password        =   kamailiorw
#ul_show_cmd        =   /usr/sbin/kamctl online
#ul_rm_cmd      =   /usr/sbin/kamctl ul rm
#domain         =   sip.zadarma.com

use strict;
use DBI();
use Logic::Tools;

# Задаем pid файл и пользователя из под которого запускаем демона
my $runas_user = 'root';
my $lock_file = '/var/run/repair_register.pid';

my $tools=Logic::Tools->new(config_file =>  '/etc/project/register-repair.ini',
                            lock_file   =>  $lock_file,
                            runas_user  =>  $runas_user,
                            logfile     =>  '/var/log/project/register_repair.log',
                            logsize     =>  '100Mb',
                            log_num     =>  4);

my $db_host=$tools->read_config( 'repair_register', 'db_host');
my $db=$tools->read_config( 'repair_register', 'db');
my $location_table=$tools->read_config( 'repair_register', 'location_table');

my $db_user=$tools->read_config( 'repair_register', 'db_user');
my $db_password=$tools->read_config( 'repair_register', 'db_password');

my $ul_show_cmd=$tools->read_config( 'repair_register', 'ul_show_cmd');
my $ul_rm_cmd=$tools->read_config( 'repair_register', 'ul_rm_cmd');

my $domain=$tools->read_config( 'repair_register', 'domain');

my $timeout=$tools->read_config( 'repair_register', 'timeout');


################### задаём запросы для БД ##############################
my %query;
#получение информации, зарегистрирован или нет
$query{'check_location'} = <<EOF;
SELECT
    count(*) as count_of_reg
FROM
    $db.$location_table
WHERE
    username=?;
EOF

#проверка не запущен ли этот процесс
$tools->check_proc();

my $dbh;
eval 
{
    $dbh=DBI->connect("DBI:mysql:$db;host=$db_host","$db_user",$db_password) or die "Error: не удается подключиться к базе данных $db $db_host $db_user $!\n";  
};
if ($@) 
{
    die "Error: не удается подключиться к базе данных $db $db_host $db_user $DBI::errstr\n";
}

$dbh->{mysql_auto_reconnect} = 1;

$tools->logprint("info","вход в цикл");

#проверка не запущен ли этот процесс
$tools->check_proc();

#запускаем как демон
$tools->supervisor_start_daemon();



while(1)
{
    
    my $registed_users=`$ul_show_cmd`;
        
    foreach(split("\n",$registed_users))
    {
        chomp;

        if($_=~/^[\d\-]+$/)
        {
            my $sth=$dbh->prepare($query{'check_location'});

            $tools->logprint("info","проверяем пользователя $_");

            eval 
            {
                $sth->execute($_);
            };
            if ($@) 
            {
                $tools->logprint("error","ошибка выполнения запроса $query{'check_location'},$_: $DBI::errstr");
            }
            
            my $count_of_reg=$sth->fetchrow_array();
            
            if($count_of_reg==0)
            {
                my $cmd=$ul_rm_cmd." ".$_."@".$domain;
                $tools->logprint("warning","$_ - количество регистраций: $count_of_reg, рассинхронизация, выполняем $cmd");
                eval 
                {
                    `$cmd`;
                };
                if ($@) 
                {
                    $tools->logprint("error","что-то пошло не так $!");
                }
            }
            $sth->finish();
        }
    }
    sleep($timeout);
}
