#!/usr/bin/env perl

###########################################################################
#                                                                         #
# Cluster Tools: cl-run.pl                                                #
# Copyright 2007-2011, Albert P. Tobey <tobert@gmail.com>                 #
#                                                                         #
###########################################################################

=head1 NAME

cl-run.pl - run commands in parallel across the cluster

=head1 SYNOPSIS

This script parallelizes ssh access to hosts.

 cl-run.pl -s $SCRIPT    [-l $FILE] [-r $FILE] [-e $FILE] [-b] [-t] [-d] [-a] [-n] [-h] [-p "SCRIPT_PARAMS"]
 cl-run.pl -c '$COMMAND' [-l $FILE] [-r $FILE] [-e $FILE] [-b] [-t] [-d] [-a] [-n] [-h]
        -s: script/program to copy out then run
        -c: command to run on each host
                - this will be written to a mini shell script then pushed out
        -l: file to write output into on the local host
        -r: place to write program output on the remote hosts
                - this only creates a shell variable in the command scripts that can
                  be redirected to using \$output
        -e: file to write errors to
        -b: background the jobs on the remote host
                - equivalent to \"nohup command &\"
        -x: run as root through sudo (requires NOPASSWD: on remote host)
        -h: print this message

=cut

use strict;
use warnings;
use Pod::Usage;
use Getopt::Long;
use File::Copy qw( copy );
use IO::Handle;
use Sys::Hostname;

use FindBin qw($Bin);
use lib $Bin;
use DshPerlHostLoop;

select(STDERR);

our $errfile           = "&1";
our $tag_local_output  = undef;
our $local_output_file = undef;
our $remote_output     = undef;
our $background        = undef;
our $command           = undef;
our $script            = undef;
our $script_parameters = undef;
our $sudo              = undef;
our $nowrap            = undef;
our $help              = undef;

GetOptions(
    "s=s" => \$script,
    "p=s" => \$script_parameters,
    "c=s" => \$command,
    "l=s" => \$local_output_file,
    "r=s" => \$remote_output,
    "e=s" => \$errfile,
    "b"   => \$background,
    "x"   => \$sudo,
    "n"   => \$nowrap,
    "h"   => \$help
);

if ( $help || (!$command && !$script) ) {
    pod2usage();
}

if ( $script && $command ) {
    pod2usage( -message => "-s and -c are mutually exclusive" );
}

func_loop( \&runit );

sub runit {
    my( $host, $comment ) = @_;
    my $cmdfile;

    if ($nowrap) {
        $cmdfile = $command;
    }
    else {
        $cmdfile = create_command_file( $command, $script, {
            CNAME   => $host,
            COMMENT => $comment,
            ORIGIN  => Sys::Hostname::hostname()
        } );

        my $scp = "/usr/bin/scp -q $ssh_options $cmdfile $remote_user\@$host:$cmdfile";
        if (verbose()) {
            $scp =~ s/scp -q/scp/;
            print STDERR "COMMAND: $scp\n" if ( verbose() );
        }

        system( $scp );
        if ($? != 0) {
            print STDERR RED, "Could not copy command script to $host!", RESET, $/;
        }
    }

    my $shell = '/bin/bash';
    if ( $sudo ) {
        $shell = 'sudo /bin/bash';
    }

    my @out = undef;
    if ( $script && $script_parameters ) {
        @out = ssh( "$remote_user\@$host", "$shell $cmdfile $script_parameters" );
    } else {
        @out = ssh( "$remote_user\@$host", "$shell $cmdfile" );
    }

    my $fh;
    if ( $local_output_file ) {
        lock(); # uses flock under the hood in DshPerlHostLoop
        open( $fh, ">> $local_output_file" );
        foreach my $line ( @out ) {
            print $fh "$host: $line\n";
        }
        close $fh;
        unlock();
    }
    else {
        foreach my $line ( @out ) {
            printf "%s% ${hostname_pad}s : %s%s\n", BLUE, $host, RESET, $line;
        }
    }

    exit 0;
}

sub create_command_file {
    my( $lcommand, $script, $vars ) = @_;

    my( $fh, $cmdfile ) = my_tempfile();
    if ( $command ) {
        print $fh "#!/bin/bash\n\n";
        print $fh "export DEBIAN_FRONTEND=noninteractive\n";
        print $fh "EXIT=0\n";

        foreach my $var (keys %$vars) {
            printf $fh "%s='%s' ; export %s\n", $var, $vars->{$var}, $var;
        }

        print $fh "cd /var/tmp\n";
        if ( $remote_output ) {
            print $fh "outfile=$remote_output\n";
        }
        else {
            print $fh "outfile=/var/tmp/`hostname`.output\n";
        }
        print $fh "rm -f \$outfile\n";
        if ( $background ) {
            print $fh "nohup $command &\n";
        }
        else {
            print $fh "$command\n";
        }
        print $fh "EXIT=\$?\n";
        print $fh "rm -f $cmdfile\n";
        print $fh "exit \$EXIT\n";
        close $fh;
    }
    else {
        close $fh;
        copy( $script, $cmdfile );
        chmod( 0755, $cmdfile );
    }

    return $cmdfile;
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

