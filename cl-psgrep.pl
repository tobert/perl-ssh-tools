#!/usr/bin/env perl

###########################################################################
#                                                                         #
# Cluster Tools: cl-psgrep.pl                                             #
# Copyright 2007-2011, Albert P. Tobey <tobert@gmail.com>                 #
#                                                                         #
###########################################################################

=head1 NAME

cl-psgrep.pl - ps/grep across the cluster

=head1 SYNOPSIS

This utility, rather than doing the work on its own, simply calls run.pl.  Not all of the options are passed through
and some (like -t) are implied.    Most of the time, the very simplest usage is best.

 cl-psgrep.pl snmpd

 cl-psgrep.pl [-d] [-a] [-b] [-n] [-x]
    -h: print this message

=cut

use Pod::Usage;
use Getopt::Long;

use FindBin qw($Bin);
use lib $Bin;
use DshPerlHostLoop;

our $help;
GetOptions( "h" => \$help );
if ( $help ) {
    pod2usage();
}
pod2usage() if ( @ARGV == 0 );

my $proc = pop(@ARGV);
$proc =~ s/^(.)/[$1]/;

func_loop( \&runit );

sub runit {
    my $host = shift;

    my @out = ssh( $remote_user.'@'.$host, "ps -ewwwo pid,args" );
    my $fh;
    for my $line ( @out ) {
        next unless ( $line =~ /$proc/ );
        print "$host: $line\n";
    }

    exit 0;
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
