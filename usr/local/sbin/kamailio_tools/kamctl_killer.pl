#!/usr/bin/perl

use strict;

use Logic::Tools;

# Задаем pid файл и пользователя из под которого запускаем демона
my $lock_file = '/var/run/kamctl_killer.pid';
my $runas_user = 'root';


my $tools=Logic::Tools->new(config_file	=>	'/etc/kamailio/kamailio-tools.ini',
							lock_file	=>	$lock_file,
							runas_user	=>	$runas_user,
							logfile		=>	'/var/log/kamctl_killer.log');

#проверка не запущен ли этот процесс
$tools->check_proc();

my @pid=split('\n',`/bin/ps aux | grep /usr/sbin/kamctl`);

foreach(@pid)
{
	my $pid=$_;
	$pid=~s/^\w+\s+(\d+).+$/$1/;
	my $uptime=`/bin/ps -eo pid,etime | grep $pid`;
	chomp($uptime);
	$uptime=~s/^\s(.+)$/$1/;
	$uptime=~s/^\d+\s+(.+)$/$1/;
	

	if($uptime=~/^(\d+)\-(\d)(\d)\:(\d)(\d)\:(\d)(\d)$/)
	{
		$uptime=$1*86400+($2*10+$3)*60*60+($4*10+$5)*60+$6*10+$7;
	}
	elsif($uptime=~/^(\d)(\d)\:(\d)(\d)\:(\d)(\d)$/)
	{
		$uptime=($1*10+$2)*60*60+($3*10+$4)*60+$5*10+$6;	
	}
	elsif($uptime=~/^(\d)(\d)\:(\d)(\d)$/)
	{
		$uptime=($1*10+$2)*60+$3*10+$4;	
	}


	if($uptime>60)
	{
		$tools->logprint("info","убиваем $pid");
		`/bin/kill -9 $pid`;
	}
}


