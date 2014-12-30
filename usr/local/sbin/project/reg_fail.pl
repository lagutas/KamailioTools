#!/usr/bin/perl

use strict;
#use POSIX qw(setuid getuid);
use File::Tail;
use Time::Local;
use Date::Parse;
use Logic::Tools;
use Sys::Hostname;
use DBI();



my $tools=Logic::Tools->new(config_file     =>      '/etc/project/reg-fail.ini',
                            lock_file       =>      '/var/run/reg_fail.pid',
                            runas_user      =>      'root',
                            logfile         =>      '/var/log/project/reg_fail.log',
                            logsize         =>  '100Mb',
                            log_num         =>  4);
$tools->check_proc();
$tools->supervisor_start_daemon();

my $db_host=$tools->read_config( 'reg_fail', 'db_host');
my $db=$tools->read_config( 'reg_fail', 'db');
my $k_reg_fails_table=$tools->read_config( 'reg_fail', 'k_reg_fails_table');
my $db_user=$tools->read_config( 'reg_fail', 'db_user');
my $db_password=$tools->read_config( 'reg_fail', 'db_password');
my $kamailio_warn_log=$tools->read_config( 'reg_fail', 'kamailio_warn_log');

################### задаём запросы для БД ##############################
my %query;
#insert_reg_fail - добавляем в таблицу неудачную регистрацию
$query{'insert_reg_fail'} = <<EOQ;
INSERT
INTO $db.$k_reg_fails_table
    (id,
    username,
    domain,
    cause_num,
    cause_name,
    datetime,
    ua,
    ip,
    hostname)
VALUES
    (NULL,
    ?,
    ?,
    ?,
    ?,
    Now(),
    ?,
    ?,
    ?);
EOQ

my $dbh;
eval 
{
    $dbh=DBI->connect("DBI:mysql:$db;host=$db_host",$db_user,$db_password);
};
if ($@) 
{
    die "Error: не удается подключиться к базе данных $db $db_host $db_user $DBI::errstr\n"
}

$dbh->{mysql_auto_reconnect} = 1;



my $hostname = hostname;

$tools->logprint("info","Запуск программы мониторинга $kamailio_warn_log на $hostname");
while (1) 
{
    my $file=File::Tail->new(
                                name        =>  $kamailio_warn_log,
                                maxinterval =>  1,
                                interval    =>  1,
                                adjustafter =>  7,
                            );

    while(defined(my $line=$file->read)) 
    {
        my $time = timelocal(localtime());
        if($line =~ /([A-Z][a-z]{2}\s+\d+\s+[0-9:]+)\s+/)
        {
            my $newlogdate = str2time($1);
            if(($time-$newlogdate)>=360)
            {
                $tools->logprint("info","возможно дискриптор закрыт, переоткрываем файл");
                last;
            }
        }

        if($line=~/auth failed/)
        {
        
            if($line=~/^.+auth failed,\sstatus\s-(\d),\s([\w\s]+):\sM=REGISTER\sRURI=.+\sF=sip:(.+)\@.+\s.+\sIP=([\d\.]+)\sdestination\s-\s(.+)\sUA=(.+)$/)
            {
                $tools->logprint("info","добавляем в БД запись $1 $2 $3 $4 $5 $6 $hostname");
                eval 
                {
                    $dbh->do($query{'insert_reg_fail'},undef,$3,$5,$1,$2,$6,$4,$hostname);
                };
                if ($@) 
                {
                    $tools->logprint("error","ошибка выполнения запроса $query{'insert_reg_fail'},undef,$3,$5,$1,$2,$6,$4,$hostname  : $DBI::errstr");
                }
                
            }
        }

    };
    sleep(1);
}