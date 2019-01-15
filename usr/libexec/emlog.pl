#!/usr/bin/perl -T

#
# Copyright (c) 2013 Apple Inc. All Rights Reserved.
#
# IMPORTANT NOTE: This file is licensed only for use on Apple-branded
# computers and is subject to the terms and conditions of the Apple Software
# License Agreement accompanying the package this file is a part of.
# You may not port this file to another platform without Apple's written consent.

#
# Log scraper
# takes input from a local socket with the -p option or from stdin or with a -l to only process one line from stdin
#
# grabs errors from ssh & ftpd
#
use Socket;
use IO::Socket;
use strict;
use warnings;

use constant MAX_MSG_LEN  => 5000;
my $OUTSTREAM;


$SIG{'INT'} = sub { exit 0 };

{
	delete @ENV{qw(IFS CDPATH PATH ENV BASH_ENV)};	# clean up the path
	
	open $OUTSTREAM, "|/usr/libexec/xssendevent" or die "Cannot launch /usr/libexec/xssendevent $!";
	
	while (<STDIN>) {
		processMessage($_);
		if(($#ARGV > 1) && ($ARGV[0] eq '-l'))	# have we been launched by launchd? if so we are only interested in one line (for now...)
		{
			exit 0;
		}
	} # end loop
}


# resolveAddress(string)
sub resolveAddress
{
	my $hent;
	#print "resolving " . $_[0] . "\n";
    $hent = gethostbyname($_[0]);
	if(defined $hent)
	{
		return inet_ntoa($hent);
	} else {
		return $_[0];
	}
};

# processMessage(string)
# need to cope with the RFC5424 changes to the message line:
# they encode the Facility & Priority at the beginning in angle brackets, overwriting
# the day name.  e.g. "<83>Feb 17" rather than "Wed Feb 17"
#
# if the log string begins with '<' one to three digits '>' letter*
# replace with the original contents with a space between the '>' and the next char
# e.g. insert a space
sub processMessage
{
	my $username = "";
	my $address = "";
	my $eventString = "";
	my $logLine = $_[0];
	
	$logLine =~ s/^(<\d{1,3}>)(\S)/$1 $2/;
	
	my @fields = split(' ',$logLine);
	my $totalFields = @fields;
	if($totalFields < 6)
	{
		return 0;
	}
	
	
	# Below are some examples of log scraping for sshd & ftp. 
	
	if($fields[4] =~ /sshd/)	# process sshd messages
	{
        if(($fields[5] eq "Received") &&
            ($fields[6] eq "disconnect") &&
            ($fields[11] eq "Bye"))
		{
			$address = $fields[8];
			#remove the trailing ':'
			chop($address);
			#print "address is " . $address . "\n";
			$eventString = "{ eventType = auth.failure; eventSource = emlog.pl; eventDetails = {clientIP = \"$address\"; protocolName = \"SSH\";};}";
		}
		elsif(($fields[5] eq "Invalid") && ($fields[6] eq "user"))
		{
			$address = $fields[$totalFields - 1];
			#print "address is " . $address . "\n";
			$eventString = "{ eventType = auth.failure; eventSource = emlog.pl; eventDetails = {clientIP = \"$address\"; protocolName = \"SSH\";};}";
		}

        
# old checks, subsumed by the BSM audit mechanism
#
#		if(($fields[6] eq "error:") && ($fields[7] eq "PAM:"))
#		{
#			if(($fields[8] eq "Authentication") || ($fields[8] eq "authentication") )
#			{
#				$username = $fields[13];
#				if($fields[$totalFields - 2] eq "via")
#				{
#					$address = resolveAddress($fields[$totalFields - 3]);
#				} else {
#					$address = resolveAddress($fields[$totalFields - 1]);
#				}
#			} else {
#				$username = $fields[13];
#				if($fields[$totalFields - 2] eq "via")
#				{
#					$address = resolveAddress($fields[$totalFields - 3]);
#				} else {
#			$address = resolveAddress($fields[$totalFields - 1]);
#		}
#	}
#	$username =~ tr/A-Za-z0-9_-//cd;
#	$address =~ tr/\[\]:%A-Za-z0-9.//cd;
#	$eventString = "{ eventType = auth.failure; eventSource = emlog.pl; eventDetails = {username = \"$username\"; clientIP = \"$address\"; protocolName = \"SSH\";};}";
#}
#elsif($fields[6] eq "Failed")
#{
#	if($fields[7] eq "none")
#	{
#		$username = $fields[11];
#		$address = resolveAddress($fields[$totalFields - 1]);
#	} else {
#		$username = $fields[11];
#		$address = resolveAddress($fields[$totalFields - 4]);
#	}
#	$username =~ tr/A-Za-z0-9_-//cd;
#	$address =~ tr/\[\]:%A-Za-z0-9.//cd;
#	$eventString = "{ eventType = auth.failure; eventSource = emlog.pl; eventDetails = {username = \"$username\"; clientIP = \"$address\"; protocolName = \"SSH\";};}";
#
#}
#elsif ($fields[6] eq "Invalid" && $fields[7] eq "user")
#{
#	$username = $fields[8];
#	$address = resolveAddress($fields[$totalFields - 1]);
#	$username =~ tr/A-Za-z0-9_-//cd;
#	$address =~ tr/\[\]:%A-Za-z0-9.//cd;
#	$eventString = "{ eventType = auth.failure; eventSource = emlog.pl; eventDetails = {username = \"$username\"; clientIP = \"$address\"; protocolName = \"SSH\";};}";
#}
#elsif($fields[6] eq "Accepted")
#{
#	$username = $fields[9];
#	$address = resolveAddress($fields[$totalFields - 4]);
#	$username =~ tr/A-Za-z0-9_-//cd;
#	$address =~ tr/\[\]:%A-Za-z0-9.//cd;
#	$eventString = "{ eventType = auth.success; eventSource = emlog.pl; eventDetails = {username = \"$username\"; clientIP = \"$address\"; protocolName = \"SSH\";};}";
#}
#elsif(($fields[6] eq "Did") && ($fields[7] eq "not") && ($fields[9] eq "identification"))
#{
#	$address = resolveAddress($fields[$totalFields - 1]);
#	$address =~ tr/\[\]:%A-Za-z0-9.//cd;
#	$eventString = "{ eventType = network.probe; eventSource = emlog.pl; eventDetails = #{sourceIP = \"$address\"; port = 22;};}";
#}
		
		if(!$eventString eq "") {
			print $OUTSTREAM $eventString;
			print $OUTSTREAM "\n";
			#print  $eventString . "\n";
		}
	}
	
	if(0)
	#if($fields[5] =~ /ftpd/)
	{
		if(($fields[6] eq "Failed") && ($fields[7] eq "authentication"))
		{
			my $addr = $fields[10];
			$addr =~ s/\[//;
			$addr =~ s/\]//;
			$eventString = "{ eventType = auth.failure; eventSource = emlog.pl; eventDetails = {clientIP = \"$addr\"; hostPort = 21; protocolName = \"ftp\";};}";
		}
		
		if(!$eventString eq "") {
			print $OUTSTREAM $eventString;
			print $OUTSTREAM "\n";
			#print  $eventString . "\n";
		}
	
	}
};

