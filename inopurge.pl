#!/usr/bin/perl
########################################################################
# inotify purge for varnish
#
# Author:iwana(trout)
# Version 0.0.2(2009/12/13)
# HP:http://xcir.net/
# for perl5.8.8
########################################################################
use strict;
use Config;
$Config{useithreads} or die;
use v5.8.8;
use warnings;
use Linux::Inotify2;
use AnyEvent;
use Net::HTTP;
use threads;
use threads::shared;
use Error qw(:try);

########################################################################
#

#//sample varnish vcl settings
#sub vcl_recv{
#	if(req.request == "PURGE"){
#		ban("req.url ~ " + req.url);
#		error 200 "purged.";
#	}
#}

#settings

#monitored root dir
my $watch_dir		 = '/var/www/html';

#replace rule(src)
my $src_regex		="^$watch_dir";

#monitored file(regex)
my $accept_regex	='\.(gif|jpg|png|php|txt|pl|html?)\Z';

#replace rule(dest)
my $dest_regex		='';

#varnish server list (key = Host:Port Value = true/false)
my %varnish_host	=();
	$varnish_host{"192.168.1.199:6081"}=1;
#	$varnish_host{"192.168.1.199:6082"}=1; #multiple server

#alias conversion
my %alias			=();
	$alias{'index\.(html?|php|pl)$'}='';

#purge request prefix
my $prefix			='^';

#purge request suffix
my $suffix			='(\\\\?[^/]+)?$';

#purge request interval(sec)
my $interval		=1;

#purge method
my $purge_method	='PURGE';

#success code
my $success_code	=200;

########################################################################

#trap SIGINT
my $abort : shared = 0;
$SIG{INT} = \&do_sigint;

#inotify
my $inotify = Linux::Inotify2->new or die $!;

#monitor event
my $watch_mask =IN_CREATE|IN_DELETE|IN_MODIFY|IN_MOVE|IN_ATTRIB|IN_MASK_ADD;
my %urllist :shared=();

#add sub directory
my @list =dirchk($watch_dir);
push(@list,$watch_dir);



#gen inotify
foreach my $v ( @list ){
	$inotify->watch(
		$v,
		$watch_mask,
		\&_cb_inotify
	);
}

my $inotify_w = AnyEvent->io(
	fh   => $inotify->fileno,
	poll => 'r',
	cb   => sub { $inotify->poll }
);

#gen purge thread
my $thr = threads->new(\&_purge_thread,$interval);


my($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
$year += 1900;$mon += 1;
print "#start:$year/$mon/$mday $hour:$min:$sec\n\n";

#start monitor
AnyEvent->condvar->recv;

#join thread
$thr->join();
exit();

########################################################################

#get sigint
sub do_sigint{
	my($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
	$year += 1900;$mon += 1;
	print "#ABORT:$year/$mon/$mday $hour:$min:$sec\n";
	$abort=1;
}

#purge thread
sub _purge_thread{
	my( $inter_sec ) = @_;
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst);
	while(1){
		if($abort){
#abort(get sigint)
			($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
			print "#THREAD-ABORT:$year/$mon/$mday $hour:$min:$sec\n";
			threads->detach();
			exit();
		}
		if(keys(%urllist)>0){
			my %cl=%urllist;
			%urllist=();
			($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
			$year += 1900;$mon += 1;
			print "#purge-start:$year/$mon/$mday $hour:$min:$sec\n";
				while ( my ($k, $v) = each(%cl) ) {
#do purge
					&purge_varnish($k);
				}
			($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
			$year += 1900;$mon += 1;
			print "#purge-end:$year/$mon/$mday $hour:$min:$sec\n\n";
		}
		sleep($inter_sec);
	}
}

#inotify callback
sub _cb_inotify{
	my $e		= shift;
	my $name	= $e->fullname;
	my $mask	= $e->mask;
	if(($mask & (IN_CREATE |IN_ISDIR)) ==(IN_CREATE |IN_ISDIR)){
		$inotify->watch(
			$name,
			$watch_mask,
			\&_cb_inotify
		);
		
		print "#add-watch:$name\n";
	}else{
		if($name=~/$accept_regex/i){
#add purge list
			$name=~s/$src_regex/$dest_regex/;
			$urllist{$prefix.$name.$suffix}=1;
			while ( my ($src, $dest) = each(%alias) ) {
				$name=~s/$src/$dest/i;
			}
			$urllist{$prefix.$name.$suffix}=1;
		}
	}
}
#get directory
sub dirchk{
	my( $sBaseDir ) = @_;
	my( @FileLists, $sFileName,@list );
	
	@FileLists = glob( $sBaseDir.'/*' );
	foreach $sFileName ( sort( @FileLists ) ){
		if(-d $sFileName){
			push(@list,&dirchk($sFileName));
			push(@list,$sFileName);
		}
	}
	return @list;
}

#gen request
sub req_gen{
	my ($url)=@_;
		return ($purge_method,$url,'Accept', '*/*');
}

#send to purge
sub purge_varnish{
	my($url)=@_;
	my @spl;my $port;my $host;
	while ( my ($raw, $mode) = each(%varnish_host) ) {
		if(!$mode){next;}
		@spl = split(/:/, $raw);
		$host = $spl[0];
		if(@spl == 1){
			$port = 80;
		}else{
			$port = $spl[1];
		}
		my $varnish=Net::HTTP->new(
			Host		=> $host,
			PeerPort	=> $port,
			Timeout		=> 2
		);
		try{
			$varnish->write_request(&req_gen($url));
			my ($code, $msg) = $varnish->read_response_headers;
			if($code == $success_code){
				print "#purge-success:$host:$port $url ($code:$msg)\n";
			}else{
				print "#purge-failed:$host:$port $url ($code:$msg)\n";
			}
		}catch Error with{
			print "#purge-failed:$host:$port $url\n";
		};
			
		
	}
}

