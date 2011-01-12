#!/usr/bin/perl

###########################################################################
#                                                                         #
# Cluster Tools: cluster_netstat.pl                                       #
# Copyright 2007-2010, Albert P. Tobey <tobert@gmail.com>                 #
#                                                                         #
###########################################################################

=head1 NAME

Cluster Netstat - display cluster network usage

=head1 DESCRIPTION

This program opens persistent ssh connections to each of the cluster nodes and
keeps them open until the user quits.

=cut

use strict;
use warnings;
use Carp;
use Pod::Usage;
use Getopt::Long;
use Time::HiRes qw(time);
use Net::SSH2;

use FindBin qw($Bin);
use lib $Bin;
use DshPerlHostLoop;

our @interfaces;
our $sleep = 2;
our %osnums = (
    linux   => 0, Linux   => 0,
    solaris => 1, SunOS   => 1
);
our @commands = (
    '/bin/cat /proc/net/dev',
    '/usr/sbin/dladm show-link -s -o link,rbytes,obytes,ierrors,oerrors -p'
);

# use a libssh2 (Net::SSH2) instead of shelling out to ssh
# it's a lot more efficient over the long times this can be
# left running

my @ssh;
my @sorted_host_list;

foreach my $host ( reverse hostlist() ) {
    # connect to the host over ssh
    print "Connecting to $host via SSH ... ";
    my $ssh = libssh2($host);
    print "connected.\n";

    # find out if it's linux or solaris
    my( $os ) = libssh2_slurp_cmd( $ssh, 'uname' );
    chomp $os;
    my $osnum = $osnums{ $os };

    # set up the polling command and add to the poll list
	push @ssh, [ $host, $ssh, $commands[$osnum], $osnum ];
    push @sorted_host_list, $host;
}

#tobert@mybox:~/src/dsh-perl$ cat /proc/net/dev
#Inter-|   Receive                                                |  Transmit
# face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
#lo: 3636173666 5626431    0    0    0     0          0         0 3636173666 5626431    0    0    0     0       0          0
#eth0: 4592765291 6225806    0    0    0     0          0         0 2378883618 5545356    0    0    0     0       0          0

sub cl_netstat {
	my( $struct, %stats, %times );

	foreach my $host ( @ssh ) {
		$stats{$host->[0]} = [ libssh2_slurp_cmd( $host->[1], $host->[2] ) ];
		$times{$host->[0]} = time();
	}

	foreach my $hostname ( keys %stats ) {
		my @legend;
		foreach my $line ( @{$stats{$hostname}} ) {
			chomp $line;
			if ( $line =~ /bytes\s+packets/ ) {
				my( $junk, $rl, $tl ) = split /\|/, $line;

				@legend = map { 'r' . $_ } split( /\s+/, $rl );
				push @legend, map { 't' . $_ } split( /\s+/, $tl );
			}
			elsif ( $line =~ /^\s*(eth\d+):\s*(.*)$/ ) {
				my( $iface, $data ) = ( $1, $2 );
				my @sdata = split /\s+/, $data;
				$struct->{$hostname}->{$1} = { map { $legend[$_] => $sdata[$_] } 0 .. $#sdata };
			}
            # opensolaris dladm
            #atobey@opensolaris ~ $ dladm show-link -s -o link,rbytes,obytes,ierrors,oerrors -p
            #myri10ge1:145237963528:1777033490:4983:0
            elsif ( $line =~ /^(\w+):(\d+):(\d+):(\d+):(\d+)/ ) {
                my @parts = ( $1, $2, $3, $4, $5 );
                $struct->{$hostname}{$parts[0]} = {
                    rbytes => $parts[1],
                    tbytes => $parts[2],
                    rerrs  => $parts[3],
                    terrs  => $parts[4]
                };
            }
		}
		$struct->{$hostname}{last_update} = $times{$hostname};
	}

	return $struct;
}

sub diff_cl_netstat {
	my( $s1, $s2 ) = @_;
	my %out;

	foreach my $host ( keys %$s1 ) {
		my @host_traffic;
		foreach my $iface ( keys %{$s1->{$host}} ) {
			next if ( $iface =~ /^lo/ or $iface eq 'last_update' );
                #next if ( @interfaces != 0 && (grep(/^$parts[0]$/, @interfaces)) == 0 );
			my $rdiff = $s1->{$host}{$iface}{rbytes} - $s2->{$host}{$iface}{rbytes};
			my $tdiff = $s1->{$host}{$iface}{tbytes} - $s2->{$host}{$iface}{tbytes};
			my $seconds = $s1->{$host}{last_update} - $s2->{$host}{last_update}; 

			push @host_traffic, int($rdiff / $seconds), int($tdiff / $seconds);
		}

        # for now, just set second interface to 0 if it doesn't exist
        if ( @host_traffic == 2 ) {
            push @host_traffic, 0, 0;
        }

		$out{$host} = \@host_traffic;
	}
	return %out;
}

my( $iterations, $total_send, $total_recv, %averages ) = ( 0, 0, 0, () );

my $previous = cl_netstat();
sleep 2;
while ( 1 ) {
	my $current = cl_netstat();
	$iterations++;

	my %diff = diff_cl_netstat( $current, $previous );
	$previous = $current;

	printf "% 12s: % 13s % 13s => % 13s / % 13s  % 13s / % 13s\n",
		qw( hostname eth0_total eth1_total eth0_recv eth0_send eth1_recv eth1_send );
	#          www.tobert.org:    8487285    9772156 =>    8043608 /     443677     9265996 /     506160
	print "------------------------------------------------------------------------------------------------------------------\n";

	my $host_count = 0;
	my $host_r_total = 0;
	my $host_s_total = 0;

	foreach my $host ( @sorted_host_list ) {
		my $hostname = $host;
		$hostname =~ s/\.[a-zA-Z]+.*$//;
		printf "% 12s: % 13s % 13s => % 13s / % 13s  % 13s / % 13s\n",
			$hostname,
			c($diff{$host}->[0] + $diff{$host}->[1]),
			c($diff{$host}->[2] + $diff{$host}->[3]),
			c($diff{$host}->[0]),
			c($diff{$host}->[1]),
			c($diff{$host}->[2]),
			c($diff{$host}->[3]);
		$host_count++;
		$host_r_total += $diff{$host}->[0] + $diff{$host}->[2];
		$host_s_total += $diff{$host}->[1] + $diff{$host}->[3];
	}
	printf "Total:   % 13s         Recv: % 12s     Send: % 12s    (%s mbit/s)\n",
		c($host_r_total + $host_s_total),
		c($host_r_total),
		c($host_s_total),
		c((($host_r_total + $host_s_total)*8)/(2**20));
	
	$total_send += $host_s_total;
	$total_recv += $host_r_total;
	printf "Average: % 13s         Recv: % 12s     Send: % 12s    (%s mbit/s)\n",
		c(($total_recv + $total_send) / $iterations),
		c(($total_recv / $iterations) / $host_count),
		c(($total_send / $iterations) / $host_count),
		c(((($total_recv + $total_send) / $iterations)*8)/(2**20));

	print "\n";

	sleep $sleep;
}

# add commas
sub c {
	my $val = int(shift);	
	$val =~ s/(?<=\d)(\d{3})$/,$1/;
	$val =~ s/(?<=\d)(\d{3}),/,$1,/g;
	return $val;
}

# sets up the ssh2 connection
sub libssh2 {
	my( $hostname, $user ) = @_;

	$user ||= $ENV{USER};

	my %keys = (
		$ENV{USER} => [ $ENV{HOME}.'/.ssh/id_rsa.pub', $ENV{HOME}.'/.ssh/id_rsa' ],
        # for testing on a single machine, create a localhost-rsa key and add it to authorized_keys
		$ENV{USER} => [ $ENV{HOME}.'/.ssh/localhost-rsa.pub', $ENV{HOME}.'/.ssh/localhost-rsa' ]
        # potentially add other users/keys here for local hacks where ssh-agent
        # doesn't cover your needs
	);

	my $ssh2 = Net::SSH2->new();

	eval { $ssh2->connect( $hostname ); };
	if ( $@ ) {
		$ssh2->connect( $hostname );
	}
	my $ok = $ssh2->auth_publickey( $user, @{$keys{$user}} );
	unless ( $ok ) {
        delete $keys{$user};
        my $next_user = (keys %keys)[0];
		warn "Failed to auth as $user - trying user '$next_user'";
		$user = $next_user;
		$ok = $ssh2->auth_publickey( $user, @{$keys{$user}} );
	}
	$ok or die "Could not authenticate as $user\@$hostname using RSA.";
	
	return $ssh2;
}

sub libssh2_slurp_cmd {
	my( $ssh2, $cmd ) = @_;

	confess "Bad args." unless ( $ssh2 && $cmd );

	my $chan = $ssh2->channel();
	$chan->exec( $cmd );

	my $data = '';
	while ( !$chan->eof() ) {
		$chan->read( my $buffer, 4096 );
		$data .= $buffer;
	}

	$chan->close();

	return wantarray ? split(/[\r\n]+/, $data) : $data;
}

__END__

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2007-2010 by Al Tobey.

This is free software; you can redistribute it and/or modify it under the terms
of the Artistic License 2.0.  (Note that, unlike the Artistic License 1.0,
version 2.0 is GPL compatible by itself, hence there is no benefit to having an
Artistic 2.0 / GPL disjunction.)  See the file LICENSE for details.

=cut

