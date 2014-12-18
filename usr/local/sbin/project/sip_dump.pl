#!/usr/bin/perl

# Version 0.1.0
# скрипт для сборки в dump SIP трафика
# работает в два потока
# поток 1 запускает tcpdump
# поток 2 сортирует файлы по каталогам в формате год/месяц/дата/час/файл.pcap
# 

#config file /etc/kamailio/kamailio-tools.ini:
#[sip_dump]
#dump_duration      =   60                          #длительность одного файла в секундах
#dump_dir           =   /var/log/kamailio/sip_dump  #каталог куда складывать файлы
#max_days           =   60                          #как долго хранить файлы в днях, старые автоматически удаляются
#interface          =   venet0:0                    #интерфейс на котором слушать трафик
#tcpdump_options    =   -nq -s 0                    #опции tcpdump
#port_options       =   port 5060 and port 5065     #какие порты слушать
#tcpdump_path       =   /usr/sbin/tcpdump           #путь до tcpdump программы




use strict;


$SIG{CHLD} = 'IGNORE';

use DBI();
use Logic::Tools;
use File::stat;
use File::Copy;

my $lock_file = '/var/run/check_location.pid';
my $runas_user = 'root';

my $tools = Logic::Tools -> new(config_file =>  '/etc/project/sip-dump.ini',
                                lock_file   =>  $lock_file,
                                runas_user  =>  $runas_user,
                                logfile     =>  '/var/log/project/sip_dump.log',
                                logsize     =>  '100Mb',
                                log_num     =>  4);

$tools -> check_proc();
$tools -> supervisor_start_daemon();
$tools -> logprint("info","start sip_dump");


my $dump_duration   = $tools -> read_config('sip_dump', 'dump_duration');
my $dump_dir        = $tools -> read_config('sip_dump', 'dump_dir');
my $max_days        = $tools -> read_config('sip_dump', 'max_days');
my $interface       = $tools -> read_config('sip_dump', 'interface');
my $tcpdump_options = $tools -> read_config('sip_dump', 'tcpdump_options');
my $port_options    = $tools -> read_config('sip_dump', 'port_options');
my $tcpdump_path    = $tools -> read_config('sip_dump', 'tcpdump_path');
my $max_diff_time   = $tools -> read_config('sip_dump', 'max_diff_time');



my $tcpdump_fork_pid;
while(1)
{
    if(!defined($tcpdump_fork_pid))
    {
        $tools -> logprint("info","запуск tcpdump");
        $tcpdump_fork_pid = fork;
        if($tcpdump_fork_pid == 0)
        {
            while(1) 
            {
                $tools -> logprint("info","tcpdump работает, pid $$");
                my $tcpdump_command=$tcpdump_path." ".$tcpdump_options." -i ".$interface." -G".$dump_duration." -w ".$dump_dir."/%F--%H-%M-%S.pcap ".$port_options;
                #$tools -> logprint("info","tcpdump запукаем $tcpdump_command");
                
                if(!is_dir($dump_dir))
                {
                    $tools -> logprint("info","каталог $dump_dir не создан, создаем");
                    mkdir($dump_dir);
                }
                else
                {
                    $tools -> logprint("info","каталог $dump_dir создан");
                }
                $tools -> logprint("info","tcpdump запукаем $tcpdump_command");
                `$tcpdump_command`;
            }
        }   
    }
    else
    {
        if(!-e "/proc/$tcpdump_fork_pid")
        {
            $tools->logprint("error","форк $tcpdump_fork_pid завершил свою работу, удаляем его");
            $tcpdump_fork_pid=undef;
        }
        #my @files_list = ;
        
        foreach(glob($dump_dir.'/*'))
        {
            #получаем информацию о файле
            my $statfile = stat($_);

            my $size = $statfile->size;
            my $mtime = $statfile->mtime;

            next if (time() - $mtime < $max_diff_time);

            if ($size == 0) 
            {
                $tools -> logprint("info","файл $_ успешно удален") if (unlink($_));
                next;
            }

            if($_=~/^.+\/((\d{4})-(\d{2})-(\d{2})--(\d{2})-\d{2}-\d{2}\..+$)$/)
            {
                if(!is_dir($dump_dir."/$2"))
                {
                    $tools -> logprint("info","каталог $dump_dir"."/$2"." не создан, создаем");
                    mkdir($dump_dir."/$2");
                }

                if(!is_dir($dump_dir."/$2/$3"))
                {
                    $tools -> logprint("info","каталог $dump_dir"."/$2/$3"." не создан, создаем");
                    mkdir($dump_dir."/$2/$3");
                }

                if(!is_dir($dump_dir."/$2/$3/$4"))
                {
                    $tools -> logprint("info","каталог $dump_dir"."/$2/$3/$4"." не создан, создаем");
                    mkdir($dump_dir."/$2/$3/$4");
                }

                if(!is_dir($dump_dir."/$2/$3/$4/$5"))
                {
                    $tools -> logprint("info","каталог $dump_dir"."/$2/$3/$4/$5"." не создан, создаем");
                    mkdir($dump_dir."/$2/$3/$4/$5");
                }

                move("$_", $dump_dir."/$2/$3/$4/$5/".$1) or die "не удалост перенести файл $_ -> ".$dump_dir."/$2/$3/$4/$5/".$1."\n";
            }
        }
    }
    
    #$tools -> logprint("info","-----------------------------------------");

    opendir(my $year_dir, $dump_dir) || $tools -> logprint("warning","не удалось открыть каталог $dump_dir: $!");

    #перебираем папки годов
    foreach my $year (readdir($year_dir))
    {
        if(is_dir($dump_dir."/".$year) && $year=~/\d+/)
        {
            #перебираем папки месяцев
            opendir(my $month_dir,$dump_dir."/".$year) || $tools -> logprint("warning","не удалось открыть каталог $dump_dir"."/".$year.": $!"); 

            my @months=readdir($month_dir);

            #если функция opendir видит в каталоге только 2 объекта . и .., то значит каталог пустой
            if(scalar(@months)==2)
            {
                $tools -> logprint("info","каталог ".$dump_dir."/".$year." успешно удален") if rmdir($dump_dir."/".$year);
            }

            foreach my $month (@months)
            {
                if(is_dir($dump_dir."/".$year."/".$month) && $month=~/\d+/)
                {
                    #перебираем папки дней
                    opendir(my $day_dir,$dump_dir."/".$year."/".$month) || $tools -> logprint("warning","не удалось открыть каталог $dump_dir"."/".$year."/".$month.": $!"); 
                    
                    my @days=readdir($day_dir);

                    #если функция opendir видит в каталоге только 2 объекта . и .., то значит каталог пустой
                    if(scalar(@days)==2)
                    {
                        $tools -> logprint("info","каталог ".$dump_dir."/".$year."/".$month." успешно удален") if rmdir($dump_dir."/".$year."/".$month);
                    }

                    foreach my $day (@days)
                    {
                        if(is_dir($dump_dir."/".$year."/".$month."/".$day) && $day=~/\d+/)
                        {
                            #перебираем папки часов
                            opendir(my $hour_dir,$dump_dir."/".$year."/".$month."/".$day) || $tools -> logprint("warning","не удалось открыть каталог $dump_dir"."/".$year."/".$month."/".$day.": $!"); 

                            my @hours=readdir($hour_dir);

                            #если функция opendir видит в каталоге только 2 объекта . и .., то значит каталог пустой
                            if(scalar(@hours)==2)
                            {
                                $tools -> logprint("info","каталог ".$dump_dir."/".$year."/".$month."/".$day." успешно удален") if rmdir($dump_dir."/".$year."/".$month."/".$day);
                            }

                            foreach my $hour (@hours)
                            {
                                if(is_dir($dump_dir."/".$year."/".$month."/".$day."/".$hour) && $hour=~/\d+/)
                                {
                                    
                                    my @file_list=glob($dump_dir."/".$year."/".$month."/".$day."/".$hour.'/*');

                                    #$tools -> logprint("info","проверяем каталог ".$dump_dir."/".$year."/".$month."/".$day."/".$hour."  количество файлов в каталоге - ".scalar(@file_list));

                                    if(scalar(@file_list)==0)
                                    {
                                        $tools -> logprint("info","каталог ".$dump_dir."/".$year."/".$month."/".$day."/".$hour." успешно удален") if rmdir($dump_dir."/".$year."/".$month."/".$day."/".$hour);
                                    }


                                    foreach(@file_list)
                                    {
                                        my $statfile = stat($_);

                                        #если дата последнего изменения файла, отличается от текущей более чем на $max_days дней, то этот файл удаляем
                                        if (time() - $statfile->mtime > $max_days*24*60*60)
                                        {
                                            $tools -> logprint("info","файл $_ успешно удален") if (unlink($_));
                                        }
                                    }
                                }
                            }
                            closedir $hour_dir;        
                        }
                    }
                    closedir $day_dir;        
                }
            }
            closedir $month_dir;
        }
    }

    closedir $year_dir;


    sleep(1);
}


sub is_dir
{
    if ( -d $_[0] ) 
    {
        return 1;
    } 
    else 
    { 
        return 0; 
    }
}