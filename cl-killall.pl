#!/usr/bin/env perl
$|++;

###########################################################################
#                                                                         #
# Cluster Tools: cl-killall.pl                                            #
# Copyright 2007-2013, Albert P. Tobey <tobert@gmail.com>                 #
#                                                                         #
###########################################################################

=head1 NAME

cl-killall.pl - run killall across the cluster

=head1 SYNOPSIS

 cl-killall.pl [-s SIG] [-d] [-h] $PROCESS_NAME
     -s: which signal to send (e.g. 9, HUP) 
     -h: show this help text

 cl-killall.pl -s HUP init
 cl-killall.pl -s 9 foobar

=cut

use strict;
use warnings;
use Pod::Usage;
use Getopt::Long;
use Scalar::Util qw(looks_like_number);

use FindBin qw($Bin);
use lib $Bin;
use DshPerlHostLoop;

our $signal        = undef;
our $help          = undef;
our $command       = '/usr/bin/killall ';

GetOptions(
    "s:s" => \$signal,
    "h"   => \$help
);

if ( $help ) {
    pod2usage();
}
unless ( @ARGV > 0 ) {
    pod2usage( -message => "Not enough arguments.   At least a program name to kill is required." );
}

if ( $signal ) {
    pod2usage( -message => "Invalid signal '$signal'." )
        unless ( looks_like_number($signal) or $signal =~ /^(?:HUP|USR1|USR2)$/ );

    $command .= "-$signal ";
}

$command .= join(' ', @ARGV);

func_loop( \&runit );

sub runit {
    my $host = shift;
    my @out = ssh( $host, $command );
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
