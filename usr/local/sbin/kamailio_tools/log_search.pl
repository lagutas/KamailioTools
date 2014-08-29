#!/usr/bin/perl

use Compress::Zlib;

use strict;

my $dir=shift;
my $flnm_mask=shift;
my $regexp=shift;


my @files_list = glob($dir.'/'.$flnm_mask);

foreach(@files_list)
{
	my $filename=$_;
	print "$filename\n";
	our $gzInput = gzopen($filename, "rb") or die "gzopen: $gzerrno\n";
	while(my $bytesRead = $gzInput->gzreadline($_))
	{
		
		if($_=~/$regexp/)
		{
			print $filename." - ".$_."\n";	
		}
	}

}