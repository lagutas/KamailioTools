#!/usr/bin/perl

use strict;

my $dir=shift;
my $string=shift;




opendir(my $hour_dir, $dir);


#перебираем папки внутри и помещаем их в $file_dirs
my @file_dirs;
foreach my $hour_dir (readdir($hour_dir))
{
    if(is_dir($dir."/".$hour_dir) && $hour_dir=~/\d+/)
    {
        push(@file_dirs,$hour_dir);
    }
}

@file_dirs = sort { $a <=> $b } @file_dirs;

foreach(@file_dirs)
{
    my @pcap_files=glob($dir."/".$_.'/*.pcap*');
    foreach (@pcap_files) 
    {
        
        my $file = $_;
        open FH, "gunzip -c $_ | ";

        while(<FH>)
        {  
            chomp;
            if($_=~/$string/)
            {
                print "file $file\n";
                print "$_\n";
            }
            
        }
    }
}
print "\n";



closedir $hour_dir;

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