#!/usr/bin/env perl
$|++;

###########################################################################
#                                                                         #
# Cluster Tools: cl-ping.pl                                               #
# Copyright 2007-2011, Albert P. Tobey <tobert@gmail.com>                 #
#                                                                         #
###########################################################################

=head1 NAME

cl-ping.pl - ping the cluster

=head1 SYNOPSIS

 cl-ping.pl

=cut

use strict;
use warnings;
use Getopt::Long;
use Pod::Usage;

use FindBin qw($Bin);
use lib $Bin;
use DshPerlHostLoop;

func_loop( sub {
    my $hostname = shift;

    my @out = `ping -c 1 -W 2 $hostname 2>&1`;

    if ($? != 0) {
      print "DOWN: $hostname\n";
    }

    print grep {/bytes from/} @out;
} );

# vim: et ts=4 sw=4 ai smarttab

__END__

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2007-2011 by Al Tobey.

This is free software; you can redistribute it and/or modify it under the terms
of the Artistic License 2.0.  (Note that, unlike the Artistic License 1.0,
version 2.0 is GPL compatible by itself, hence there is no benefit to having an
Artistic 2.0 / GPL disjunction.)  See the file LICENSE for details.

=cut
