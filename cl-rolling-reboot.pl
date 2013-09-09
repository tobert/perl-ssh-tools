#!/usr/bin/env perl
$|++;

###########################################################################
#                                                                         #
# Cluster Tools: cl-rolling-restart.pl                                    #
# Copyright 2013, Albert P. Tobey <tobert@gmail.com>                      #
#                                                                         #
###########################################################################

=head1 NAME

cl-rolling-restart.pl - reboot a cluster as safely as possible

=head1 SYNOPSIS

This script attempts to reboot a cluster safely. It steps through the host
list serially, rebooting one node at a time and only progresses to the next
node if the previous node comes back online. It is quite verbose on purpose,
with the intent of being run in a screen session and left alone for many hours
or days to do its thing.

ICMP is used to determine basic network availability. No node is considered
actually available unless a command can be run over ssh.

Most failures are fatal.  Large clusters will typically have a few nodes down
at any given time, so those nodes are skipped if they fail an ICMP test.

When a run fails, a new list will be written to your ~/.dsh that only contains
the incomplete list, allowing you to resume easily. The name of the file and
the correct command for resuming will be printed.

 cl-rolling-restart.pl --list foo [--timeout 1800] [--wait 60]
      --timeout: number of seconds before giving up on a host
	  --wait: number of seconds to wait between reboots

=cut

use Pod::Usage;
use File::Temp qw/tempfile/;
use Getopt::Long;
use IPC::Open3;
use strict;
use warnings;

use FindBin qw($Bin);
use lib $Bin;
use DshPerlHostLoop;

our $opt_help    = undef;
our $opt_timeout = 1800; # 1/2 hour
our $opt_wait    = 60;   # one minute

GetOptions(
    "timeout:i" => \$opt_timeout,
    "wait:i"    => \$opt_wait,
    "help"      => \$opt_help,   "h" => \$opt_help
);

if ($opt_help) {
    pod2usage();
}

=item ping()

Ping the host once, waiting 3 seconds for a response. Returns
1 (true) on success and undef (false) on failure.

This function should move to DshPerlHostLoop at some point.

 ping($hostname);

=cut

sub ping {
    my $hostname = shift;

	my $pid = open3(my $w, my $r, my $e, '/bin/ping', '-c', '1', '-W', '3', $hostname);

	waitpid($pid, 0);

    if ($? != 0) {
		return undef;
    }

	return 1;
}

=item reboot()

SSHes in to the host and issues 'sudo reboot'. The return value is
any text printed by the reboot command, but this should not be used
to determine if it was successful.

 reboot($hostname);

=cut

sub reboot {
    my $host = shift;
    my @out = ssh("$remote_user\@$host", "sudo reboot");
	return @out;
}

=item fail()

Writes out the incomplete hosts to a new host list, prints some information,
then exits immediately with a return code of 1.

 fail(@hostlist, $index); # will exit

=cut

sub fail {
	my($hostlist, $i) = @_;
	my $now = time;

	# print out a machine list containing only the hosts that failed
	# to make resuming the reboot more convenient
	open(my $fh, "> $ENV{HOME}/.dsh/machines.reboot-failed-$now");
	for (1; $i<@$hostlist; $i++) {
		print $fh "$hostlist->[$i]\n";
	}
	close $fh;

	print "\nA machine list containing only the un-rebooted nodes has been written to:\n";
	print "$ENV{HOME}/.dsh/machines.reboot-failed-$now\n";
	print "To resume:\n";
	print "cl-rolling-reboot.pl --list reboot-failed-$now\n\n";
	exit 1;
}

=item main()

Try really hard to reboot machines without accidentally taking down more than one
node at a time.

=cut

my @hosts = hostlist();
for (my $i=0; $i<@hosts; $i++) {
	# skip hosts that are down
	next unless ping($hosts[$i]);

	# failsafe: break and fail if work hangs somewhere
	$SIG{'ALRM'} = sub {
		print "Timeout. Something hung and SIGALRM has fired. Exiting now.\n";
		fail(\@hosts, $i);
	};
	alarm($opt_timeout + $opt_wait + 600);

	my $rebooted_at = time;
	reboot($hosts[$i]);
	print "$hosts[$i]: sent reboot command ...\n";

	print "Waiting up to five minutes for the host to go offline ...\n";
	my $count = 0;
	while (1) {
		sleep 1;
		my $status = ping($hosts[$i]);

		if ($status) {
			$count++;
			if ($count % 10 == 0) {
				print "$hosts[$i] has not gone offline after $count seconds. Retrying in 10 seconds ...\n";
			}
			if ($count > 300) {
				print "$hosts[$i] has not gone offline after $count seconds.\n";
				fail(\@hosts, $i);
			}
		} else {
			print "$hosts[$i] is offline. Going to sleep for two minutes ...\n";
			last;
		}
	}

	# wait two minutes before even trying to ping the box
	sleep 120;

	print "Host has been down for at least two minutes. Will start pinging now.\n";
	$count = 0;
	my $upcount = 0;
	while (1) {
		my $status = ping($hosts[$i]);
		my $elapsed = time - $rebooted_at;

		if ($status) {
			$upcount++;
			print "$hosts[$i] network has responded to $upcount pings.\n";
			# require 5 consecutive successes before moving on
			if ($upcount == 4) {
				last;
			}
			else {
				next;
			}
		}

		# reset the counter if even a single ping fails
		$upcount = 0;

		$count++;
		if (not $status && $count % 10 == 0) {
			print "$hosts[$i] has been down for $elapsed seconds.\n";
		}

		# wait up to $opt_timeout minutes for the host to come back, if it doesn't,
		# stop trying and wait for the operator to clean up
		if ($elapsed > $opt_timeout) {
			print "Reboot of $hosts[$i] failed, it is still down after $elapsed seconds.\n";
			fail(\@hosts, $i);
		}
	}

	print "$hosts[$i] network is responding. Checking SSH in 5 minutes...\n";
	sleep 300;

	# TODO: retries?
	my @out = ssh("$remote_user\@$hosts[$i]", "uptime");
	my $flat = join(' ', map { chomp; $_ } @out);

	if ($flat =~ / up /) {
		print "\n-----------------------------------------------------------------------\n";
		print "$hosts[$i] is back online! Moving on.\n";
		print "$hosts[$i] $flat\n";
		print "-----------------------------------------------------------------------\n\n";
	} else {
		print "$hosts[$i]: could not run the uptime command.\n";
		fail(\@hosts, $i);
	}

	print "Sleeping $opt_wait seconds before moving on to the next host.\n";
	sleep $opt_wait;
}

# vim: et ts=4 sw=4 ai smarttab

__END__

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2013 by Al Tobey.

This is free software; you can redistribute it and/or modify it under the terms
of the Artistic License 2.0.  (Note that, unlike the Artistic License 1.0,
version 2.0 is GPL compatible by itself, hence there is no benefit to having an
Artistic 2.0 / GPL disjunction.)  See the file LICENSE for details.

=cut
