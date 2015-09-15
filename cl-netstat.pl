#!/usr/bin/env perl
$| = 1;

###########################################################################
#                                                                         #
# Cluster Tools: cl-netstat.pl                                            #
# Copyright 2007-2011, Albert P. Tobey <tobert@gmail.com>                 #
#                                                                         #
###########################################################################

=head1 NAME

Cluster Netstat - display cluster network usage

=head1 DESCRIPTION

This program opens persistent ssh connections to each of the cluster nodes and
keeps them open until the user quits.

In my experience, the load incurred on monitored hosts is unmeasurable.

=head1 SYNOPSIS

 cl-netstat.pl <--list LIST> <--tolerant> <--interval SECONDS> <--device DEVICE>
   --list     - the name of the list in ~/.dsh to use, e.g ~/.dsh/machines.db-prod
   --tolerant - tolerate missing/down hosts in connection creation
   --interval - how many seconds to sleep between updates
   --device   - name of the device to get io stats for, as displayed in /proc/diskstats

 cl-netstat.pl # reads ~/.dsh/machines.list
 cl-netstat.pl --list db-prod
 cl-netstat.pl --list db-prod --tolerant
 cl-netstat.pl --list db-prod --interval 5
 cl-netstat.pl --list db-prod --device md3

=head1 REQUIREMENTS

1.) password-less ssh access to all the hosts in the machine list
2.) ssh key in ~/.ssh/id_rsa or ~/.ssh/monitor-rsa
3.) ability to /bin/cat /proc/net/dev /proc/diskstats

If you want to have a special key that is restricted to the cat command, here's an example:

 no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty,command="/bin/cat /proc/net/dev /proc/diskstats" ssh-rsa AAAA...== al@mybox.com

=cut

use strict;
use warnings;
use Carp;
use Pod::Usage;
use Getopt::Long;
use Time::HiRes qw(time);
use Data::Dumper;
use Net::SSH2;
use Tie::IxHash;

use FindBin qw($Bin);
use lib $Bin;
use DshPerlHostLoop;

our @ssh;
our @interfaces;
our @sorted_host_list;
our %host_bundles;
our( $opt_device, $opt_tolerant, $opt_interval );

GetOptions(
    "device:s"   => \$opt_device,
    "tolerant"   => \$opt_tolerant,
    "interval:i" => \$opt_interval, "i:i" => \$opt_interval
);

$opt_interval ||= 2;

tie my %hosts, 'Tie::IxHash';
%hosts = hostlist(keep_comments => 1);
$hostname_pad = length('hostname: '); # reset this since this script uses short hostnames

foreach my $host ( keys %hosts ) {
    # connect to the host over ssh
    my $bundle = DshPerlHostLoop::Bundle->new({
        host    => $host,
        port    => 22
    }) ; # ssh connection + metadata

    print CYAN, "Connecting to $host via SSH ... ", RESET;
    eval {
        $bundle = libssh2_connect($host, 22);
    };
    if ($@) {
      print RED, "failed, will retry later.\n", RESET;
      print RED, "$@\n", RESET;
      $bundle->next_attempt(time + $retry_wait);
      $bundle->retries(0);
      $bundle->ssh2(undef);
    }
    else {
      print GREEN, "connected.\n", RESET;
    }

    my $hn = $host;
       $hn =~ s/\.[a-zA-Z]+.*$//;
    if (length($hn) + 2 > $hostname_pad) {
        $hostname_pad = length($hn) + 2;
    }

    $bundle->comment($hosts{$host});

    # set up the polling command and add to the poll list
    push @ssh, [ $host, $bundle, '/bin/cat /proc/net/dev /proc/diskstats' ];
    push @sorted_host_list, $host;
    $host_bundles{$host} = $bundle;
}

#tobert@mybox:~/src/dsh-perl$ cat /proc/net/dev
#Inter-|   Receive                                                |  Transmit
# face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
#lo: 3636173666 5626431    0    0    0     0          0         0 3636173666 5626431    0    0    0     0       0          0
#eth0: 4592765291 6225806    0    0    0     0          0         0 2378883618 5545356    0    0    0     0       0          0

sub cl_netstat {
    my( $struct, %stats, %times );

    foreach my $host ( @ssh ) {
        $stats{$host->[0]} = libssh2_slurp_cmd($host->[1], $host->[2]);
        next unless $stats{$host->[0]};
        $times{$host->[0]} = time();
        push @{$stats{$host->[0]}}, $host->[1]->comment || '';
    }

    foreach my $hostname ( keys %stats ) {
        # host is down
        if (not defined $stats{$hostname}) {
            $struct->{$hostname} = undef;
            next;
        }

        # pass the host comment through
        $struct->{$hostname}{comment} = pop @{$stats{$hostname}};

        my @legend;
        $struct->{$hostname}{dsk_rds} = 0; # read sectors counter
        $struct->{$hostname}{dsk_rwt} = 0; # read wait ms counter
        $struct->{$hostname}{dsk_wds} = 0; # write sectors counter
        $struct->{$hostname}{dsk_wwt} = 0; # write wait ms counter
        $struct->{$hostname}{net} = {};

        foreach my $line ( @{$stats{$hostname}} ) {
            chomp $line;
            if ( $line =~ /bytes\s+packets/ ) {
                my( $junk, $rl, $tl ) = split /\|/, $line;
                @legend = map { 'r' . $_ } split( /\s+/, $rl );
                push @legend, map { 't' . $_ } split( /\s+/, $tl );
            }
            elsif ( $line =~ /^\s*(e\w+)(\d+):\s*(.*)$/ ) {
                my( $iface, $data ) = ( $1 . $2, $3 );

                my @sdata = split /\s+/, $data;

                foreach my $idx ( 0 .. $#sdata ) {
                  $struct->{$hostname}{net}{$legend[$idx]} ||= 0;
                  $struct->{$hostname}{net}{$legend[$idx]} += $sdata[$idx] || 0;
                }
            }
           # 8  0 sda 298890 2980 5498843 92328 10123211 2314394 134218078 10756944 0 419132 10866136
           # 8  5 sda5 5540 826 44511 1528 15558 55975 572334 68312 0 2932 69848
           # 8 32 sdc 913492 273 183151490 8217340 2047310 0 37711114 1259728 0 1267508 9476068
           # 8 16 sdb 2640 380 18329 2860 1751748 13461886 121702720 249041290 78 2654720 249048720
           # 8 1  sda1 35383589 4096190 515794290 173085956 58990656 100542811 1276270912 205189188 0 135658516 378268412
           # EC2 machines get disks with partitions but not whole disks
           # TODO: sort out devices to make sure partitions are not double-counted with whole devices
           #
           # from Documentation/iostats.txt:
           # Field  1 -- # of reads completed
           # Field  2 -- # of reads merged
           # Field  3 -- # of sectors read
           # Field  4 -- # of milliseconds spent reading
           # Field  5 -- # of writes completed
           # Field  6 -- # of writes merged
           # Field  7 -- # of sectors written
           # Field  8 -- # of milliseconds spent writing
           # Field  9 -- # of I/Os currently in progress
           # Field 10 -- # of milliseconds spent doing I/Os
           # Field 11 -- weighted # of milliseconds spent doing I/Os
           #
           # capture:           major minor   $1      $2      $3      $4      $5      $6      $7      $8      $9      $10 ...
           elsif ($line =~ /^\s*\d+\s+\d+\s+(\w+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+/) {
                if (not $opt_device or $opt_device eq $1) {
                    $struct->{$hostname}{dsk_rds} += $2;
                    $struct->{$hostname}{dsk_rwt} += $5;
                    $struct->{$hostname}{dsk_wds} += $6;
                    $struct->{$hostname}{dsk_wwt} += $9;
                }
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
        if (not defined $s1->{$host}) {
            $out{$host} = undef;
            #$out{$host} = [ 0, 0, 0, 0, 0, 0 ];
            next;
        }

        my $seconds = $s1->{$host}{last_update} - $s2->{$host}{last_update}; 

        my @host_traffic;
        foreach my $iface ( sort keys %{$s1->{$host}} ) {
            if ( $iface eq 'net' ) {
                my $rdiff = $s1->{$host}{$iface}{rbytes} - $s2->{$host}{$iface}{rbytes};
                my $tdiff = $s1->{$host}{$iface}{tbytes} - $s2->{$host}{$iface}{tbytes};
                my $tput = ($s1->{$host}{$iface}{rpackets} - $s2->{$host}{$iface}{rpackets})
                         + ($s1->{$host}{$iface}{tpackets} - $s2->{$host}{$iface}{tpackets});

                # counter rollover
                if ($s1->{$host}{$iface}{rbytes} < $s2->{$host}{$iface}{rbytes}) {
                  # this trades off the accuracy of one iteration to avoid having
                  # to track deltas across iterations
                  $rdiff = $s2->{$host}{$iface}{rbytes};
                }
                if ($s1->{$host}{$iface}{tbytes} < $s2->{$host}{$iface}{tbytes}) {
                  $tdiff = $s2->{$host}{$iface}{tbytes};
                }

                # 0: read_bytesps, 1: write_bytesps
                push @host_traffic, int($rdiff / $seconds), int($tdiff / $seconds);
                # 2: total_byteps, 3: 0 (using an array here was silly, should be hash)
                push @host_traffic, int($tput / $seconds), 0;
            }
        }

        # iops
        $host_traffic[4] = ($s1->{$host}{dsk_rds} - $s2->{$host}{dsk_rds}) / $seconds;
        $host_traffic[5] = ($s1->{$host}{dsk_wds} - $s2->{$host}{dsk_wds}) / $seconds;

        # iowait
        $host_traffic[6] = ($s1->{$host}{dsk_rwt} - $s2->{$host}{dsk_rwt});
        $host_traffic[7] = ($s1->{$host}{dsk_wwt} - $s2->{$host}{dsk_wwt});

        $out{$host} = \@host_traffic;
    }
    return %out;
}

### MAIN

my($iterations, %averages) = (0, ());

# these totals are for the lifetime of this process
my($total_net_tx, $total_net_rx) = (0, 0);
my($total_disk_riops, $total_disk_wiops) = (0, 0);
my($total_disk_rwait, $total_disk_wwait) = (0, 0);

my $previous = cl_netstat();
print GREEN, "Acquired first round. Output begins in $opt_interval seconds.\n", WHITE;
sleep $opt_interval;
FOREVER: while ( 1 ) {
    my $current = cl_netstat();
    $iterations++;

    my %diff = diff_cl_netstat( $current, $previous );
    $previous = $current;

    my $header = sprintf "% ${hostname_pad}s: % 13s % 13s % 14s %8s %8s %8s %8s",
        qw( hostname net_packets net_rx_bytes net_tx_bytes dsk_riops dsk_wiops rwait_ms wwait_ms );
    print CYAN, $header, $/, '-' x length($header), $/, RESET;

    # iteration totals
    my $host_count = 0;
    my($ivl_net_rx_total, $ivl_net_tx_total) = (0, 0);
    my($ivl_riops_total, $ivl_wiops_total) = (0, 0);
    my($ivl_rwait_total, $ivl_wwait_total) = (0, 0);

    HOST: foreach my $host ( @sorted_host_list ) {
        my $hostname = $host;
        $hostname =~ s/\.[a-zA-Z]+.*$//;

        # host down, special case
        if (not defined $diff{$host}) {
            my $bundle = $host_bundles{$host};
            printf "%s% ${hostname_pad}s: disconnected, retry attempt %d in %d seconds ...%s\n",
                DKGRAY, $hostname, $bundle->retries || 1, int($bundle->next_attempt - time), RESET;
            next HOST;
        }

        # network
        printf "%s% ${hostname_pad}s: %s% 13s %s% 13s  %s% 13s%s  ",
            WHITE, $hostname,
            io_c($diff{$host}->[2], 2), # total pps
            net_c($diff{$host}->[0]),   # read bytes per second
            net_c($diff{$host}->[1]),   # write bytes per second
            RESET;

        # disk iops
        printf "%s%8s  %s%8s ",
            io_c($diff{$host}->[4]),
            io_c($diff{$host}->[5]);

        # iowait
        my $avg_rwait = $diff{$host}->[6] / ($diff{$host}->[4] || 1);
        my $avg_wwait = $diff{$host}->[7] / ($diff{$host}->[5] || 1);
        printf "%s%8s %s%8s %s%s%s\n",
            io_c($avg_rwait),
            io_c($avg_wwait),
            DKGRAY, $current->{$host}{comment} || '', RESET;

        # increment totals
        $host_count++;
        $ivl_net_rx_total += $diff{$host}->[0] + $diff{$host}->[2];
        $ivl_net_tx_total += $diff{$host}->[1] + $diff{$host}->[3];
        $ivl_riops_total += $diff{$host}->[4];
        $ivl_wiops_total += $diff{$host}->[5];
        $ivl_rwait_total += $avg_rwait;
        $ivl_wwait_total += $avg_wwait;
    }

    printf "%sNetwork total:   %s% 13s         %sRecv: %s% 12s     %sSend: %s% 12s    %s(%s MiB/s)%s\n",
        WHITE, net_c($ivl_net_rx_total + $ivl_net_tx_total, 2 * $host_count), WHITE,
        net_c($ivl_net_rx_total, $host_count), WHITE,
        net_c($ivl_net_tx_total, $host_count), WHITE,
        c(($ivl_net_rx_total + $ivl_net_tx_total)/(2**20)),
        RESET;

    $total_net_tx += $ivl_net_tx_total;
    $total_net_rx += $ivl_net_rx_total;

    printf "%sNetwork average: %s% 13s         %sRecv: %s% 12s     %sSend: %s% 12s    %s(%s MiB/s)%s\n",
        WHITE, net_c(($total_net_rx + $total_net_tx) / $iterations, 2), WHITE,
        net_c(($total_net_rx / $iterations) / $host_count), WHITE,
        net_c(($total_net_tx / $iterations) / $host_count), WHITE,
        c((($total_net_rx + $total_net_tx) / $iterations)/(2**20)),
        RESET;

    $total_disk_riops += $ivl_riops_total;
    $total_disk_wiops += $ivl_wiops_total;

    printf "%sIOPS:      %s% 10s %stotal riops %s% 10s %stotal wiops %s% 6s %savg riops %s% 6s %savg wiops%s\n",
        WHITE, io_c($ivl_riops_total, $host_count), WHITE,
        io_c($ivl_wiops_total, $host_count), WHITE,
        io_c(($total_disk_riops / $iterations) / $host_count), WHITE,
        io_c(($total_disk_wiops / $iterations) / $host_count), WHITE,
        RESET;

    $total_disk_rwait += $ivl_rwait_total;
    $total_disk_wwait += $ivl_wwait_total;

    printf "%siowait ms: %s% 10s %stotal rwait %s% 10s %stotal wwait %s% 6s %savg rwait %s% 6s %savg wwait%s\n\n",
        WHITE, io_c($ivl_rwait_total, $host_count), WHITE,
        io_c($ivl_wwait_total, $host_count), WHITE,
        io_c(($total_disk_rwait / $iterations) / $host_count), WHITE,
        io_c(($total_disk_wwait / $iterations) / $host_count), WHITE,
        RESET;

    sleep $opt_interval;
}

sub la_c {
    my($value, $factor) = @_;
    $factor ||= 1;

    if ( $value < 0.80 ) {
        return(GREEN, $value);
    }
    if ( $value < 1.20 ) {
        return(CYAN, $value);
    }
    if ( $value < 3.0 ) {
        return(YELLOW, $value);
    }
    elsif ( $value > 5.0 ) {
        return(MAGENTA, $value);
    }
    elsif ( $value > 10.0 ) {
        return(RED, $value);
    }
    return(CYAN, $value);
}

sub net_c {
    my($value, $factor) = @_;
    $factor ||= 1;
    my $val = $value / $factor;
    my $color = WHITE;

    if ($val < 1_000_000) {
        $color = GREEN;
    }
    elsif ($val < 5_000_000) {
        $color = CYAN;
    }
    elsif ($val < 20_000_000) {
        $color = YELLOW;
    }
    elsif ($val < 50_000_000) {
        $color = DKRED;
    }
    else {
        $color = RED;
    }

    return($color, c($value));
}

sub io_c {
    my($value, $factor) = @_;
    $factor ||= 1;
    my $val = $value / $factor;
    my $color = WHITE;

    if ($val < 3000) {
        $color = GREEN;
    }
    elsif ($val < 10_000) {
        $color = CYAN;
    }
    elsif ($val < 20_000) {
        $color = YELLOW;
    }
    else {
        $color = RED;
    }

    return($color, c(shift));
}

# add commas
sub c {
    my $val = int(shift);
    $val =~ s/(?<=\d)(\d{3})$/,$1/;
    $val =~ s/(?<=\d)(\d{3}),/,$1,/g;
    $val =~ s/(?<=\d)(\d{3}),/,$1,/g;
    return $val;
}

# vim: et ts=4 sw=4 ai smarttab

__END__

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2007-2011 by Al Tobey.

This is free software; you can redistribute it and/or modify it under the terms
of the Artistic License 2.0.  (Note that, unlike the Artistic License 1.0,
version 2.0 is GPL compatible by itself, hence there is no benefit to having an
Artistic 2.0 / GPL disjunction.)  See the file LICENSE for details.

=cut
