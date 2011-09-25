#!/usr/bin/perl
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
3.) ability to /bin/cat /proc/net/dev /proc/loadavg /proc/diskstats

If you want to have a special key that is restricted to the cat command, here's an example:

 no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty,command="/bin/cat /proc/net/dev /proc/loadavg /proc/diskstats" ssh-rsa AAAA...== al@mybox.com

=cut

use strict;
use warnings;
use Carp;
use Pod::Usage;
use Getopt::Long;
use Time::HiRes qw(time);
use Data::Dumper;
use Net::SSH2;

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

foreach my $host ( reverse hostlist() ) {
    # connect to the host over ssh
    my $bundle = DshPerlHostLoop::Bundle->new({ host => $host, port => 22 }) ; # ssh connection + metadata

    print BLUE, "Connecting to $host via SSH ... ", RESET;
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

    # set up the polling command and add to the poll list
    push @ssh, [ $host, $bundle, '/bin/cat /proc/net/dev /proc/loadavg /proc/diskstats' ];
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
        $times{$host->[0]} = time();
    }

    foreach my $hostname ( keys %stats ) {
        # host is down
        if (not defined $stats{$hostname}) {
            $struct->{$hostname} = undef;
            next;
        }

        my @legend;
        $struct->{$hostname}{dsk_rdi} = 0;
        $struct->{$hostname}{dsk_wdi} = 0;

        foreach my $line ( @{$stats{$hostname}} ) {
            chomp $line;
            if ( $line =~ /bytes\s+packets/ ) {
                my( $junk, $rl, $tl ) = split /\|/, $line;

                @legend = map { 'r' . $_ } split( /\s+/, $rl );

                push @legend, map { 't' . $_ } split( /\s+/, $tl );
            }
            elsif ( $line =~ /^\s*(eth[01]):\s*(.*)$/ ) {
                my( $iface, $data ) = ( $1, $2 );
                my @sdata = split /\s+/, $data;
                $struct->{$hostname}{$iface} = { map { $legend[$_] => $sdata[$_] } 0 .. $#sdata };
            }
            # load average
            # # 0.00 0.00 0.00 1/307 155781
            elsif ($line =~ /(\d+\.\d+) (\d+\.\d+) (\d+\.\d+) \d+\/\d+ \d+/) {
                $struct->{$hostname}{la_short}  = $1;
                $struct->{$hostname}{la_medium} = $2;
                $struct->{$hostname}{la_long}   = $3;
           }
           # 8  0 sda 298890 2980 5498843 92328 10123211 2314394 134218078 10756944 0 419132 10866136
           # 8  5 sda5 5540 826 44511 1528 15558 55975 572334 68312 0 2932 69848
           # 8 32 sdc 913492 273 183151490 8217340 2047310 0 37711114 1259728 0 1267508 9476068
           # 8 16 sdb 2640 380 18329 2860 1751748 13461886 121702720 249041290 78 2654720 249048720
           # 8 1  sda1 35383589 4096190 515794290 173085956 58990656 100542811 1276270912 205189188 0 135658516 378268412
           # ignore whole devices, add up paritions, because EC2 machines get disks with partitions but not whole
           # disks (fucking xen)
           # from Documentation/iostats.txt:
           # Field  1 -- # of reads completed
           # Field  2 -- # of reads merged, field 6 -- # of writes merged
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
           # example:            8     1          sda1 35383589 4096190 515794290 173085956 58990656 100542811 
           # capture:                         $1     $2                        $3
           # field:             major minor device    1      2     3     4      5   ... 6-11
           elsif ($line =~ /^\s*\d+\s+\d+\s+(\w+)\s+(\d+)\s+\d+\s+\d+\s+\d+\s+(\d+)\s+/) {
                if (not $opt_device or $opt_device eq $1) {
                    $struct->{$hostname}{dsk_rdi} += $2;
                    $struct->{$hostname}{dsk_wdi} += $3;
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
        next if not defined $s1->{$host};

        my @host_traffic;
        foreach my $iface ( sort keys %{$s1->{$host}} ) {
            if ( $iface =~ /eth\d+/ ) {
                my $rdiff = $s1->{$host}{$iface}{rbytes} - $s2->{$host}{$iface}{rbytes};
                my $tdiff = $s1->{$host}{$iface}{tbytes} - $s2->{$host}{$iface}{tbytes};
                my $seconds = $s1->{$host}{last_update} - $s2->{$host}{last_update}; 
                push @host_traffic, int($rdiff / $seconds), int($tdiff / $seconds);
            }
            #elsif ($iface =~ /^dsk_[rw]d[is]/) {
            #   print "$iface: " . Dumper($s1->{$host}{$iface});
            #}
        }

        # for now, just set second interface to 0 if it doesn't exist
        if ( @host_traffic == 2 ) {
            push @host_traffic, 0, 0;
        }

        $host_traffic[4] = $s1->{$host}{dsk_rdi} - $s2->{$host}{dsk_rdi},
        $host_traffic[5] = $s1->{$host}{dsk_wdi} - $s2->{$host}{dsk_wdi};

        $out{$host} = \@host_traffic;
    }
    return %out;
}

### MAIN

my( $iterations, $total_send, $total_recv, $total_disk_read, $total_disk_write, %averages ) = ( 0, 0, 0, 0, 0, () );

my $previous = cl_netstat();
print GREEN, "Acquired first round. Output begins in $opt_interval seconds.\n", WHITE;
sleep $opt_interval;
while ( 1 ) {
    my $current = cl_netstat();
    $iterations++;

    my %diff = diff_cl_netstat( $current, $previous );
    $previous = $current;

    my $header = sprintf "% ${hostname_pad}s: % 13s % 13s % 13s  %12s   %12s     %5s %5s %5s",
        qw( hostname eth0_total eth0_recv eth0_send read_iops write_iops 1min 5min 15min );
    print BLUE, $header, $/, '-' x length($header), $/, RESET;

    my $host_count = 0;
    my $host_r_total = 0;
    my $host_s_total = 0;
    my $host_dr_total = 0;
    my $host_dw_total = 0;

    foreach my $host ( @sorted_host_list ) {
        my $hostname = $host;
        $hostname =~ s/\.[a-zA-Z]+.*$//;

        # host down, special case
        if (not defined $diff{$host}) {
            my $bundle = $host_bundles{$host};
            printf "%s% ${hostname_pad}s: disconnected, retry attempt %d in %d seconds ...%s\n",
                DKGRAY, $hostname, $bundle->retries || 1, int($bundle->next_attempt - time), RESET;
            next;
        }

        # eth0
        printf "%s% ${hostname_pad}s: %s% 13s %s% 13s %s% 13s%s",
            WHITE, $hostname,
            net_c($diff{$host}->[0] + $diff{$host}->[1], 2),
            net_c($diff{$host}->[0]),
            net_c($diff{$host}->[1]),
            RESET;

        # disk iops
        printf "%s%12s/s %s%12s/s     ",
            io_c($diff{$host}->[4]),
            io_c($diff{$host}->[5]);

        # load average
        printf "%s%5s %s%5s %s%5s\n",
            la_c($current->{$host}{la_short}),
            la_c($current->{$host}{la_medium}),
            la_c($current->{$host}{la_long});

        $host_count++;
        $host_r_total += $diff{$host}->[0] + $diff{$host}->[2];
        $host_s_total += $diff{$host}->[1] + $diff{$host}->[3];

        $host_dr_total += $diff{$host}->[4];
        $host_dw_total += $diff{$host}->[5];
    }

    printf "%sTotal:   %s% 13s         %sRecv: %s% 12s     %sSend: %s% 12s    %s(%s mbit/s) | %s%8s %sread/s %s%8s %swrite/s%s\n",
        RESET, net_c($host_r_total + $host_s_total, 2 * $host_count),
        WHITE, net_c($host_r_total, $host_count),
        WHITE, net_c($host_s_total, $host_count),
        WHITE, c((($host_r_total + $host_s_total)*8)/(2**20)),
        WHITE, io_c($host_dr_total, $host_count),
        WHITE, io_c($host_dw_total, $host_count),
        RESET;
  
    $total_send += $host_s_total;
    $total_recv += $host_r_total;
    $total_disk_read  += $host_dr_total;
    $total_disk_write += $host_dw_total;

    printf "%sAverage: %s% 13s         %sRecv: %s% 12s     %sSend: %s% 12s    %s(%s mbit/s) | %s%8s %sread/s %s%8s %swrite/s%s\n\n",
        RESET, net_c(($total_recv + $total_send) / $iterations, 2),
        WHITE, net_c(($total_recv / $iterations) / $host_count),
        WHITE, net_c(($total_send / $iterations) / $host_count),
        WHITE, c(((($total_recv + $total_send) / $iterations)*8)/(2**20)),
        WHITE, io_c(($total_disk_read  / $iterations) / $host_count),
        WHITE, io_c(($total_disk_write / $iterations) / $host_count),
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

    return($color, c(shift));
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
    return $val;
}


__END__

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2007-2011 by Al Tobey.

This is free software; you can redistribute it and/or modify it under the terms
of the Artistic License 2.0.  (Note that, unlike the Artistic License 1.0,
version 2.0 is GPL compatible by itself, hence there is no benefit to having an
Artistic 2.0 / GPL disjunction.)  See the file LICENSE for details.

=cut
