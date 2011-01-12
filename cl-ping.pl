#!/usr/bin/perl
$|++;

###########################################################################
#                                                                         #
# Cluster Tools: ping.pl                                                  #
# Copyright 2007-2010, Albert P. Tobey <tobert@gmail.com>                 #
#                                                                         #
###########################################################################

=head1 NAME

ping.pl - ping the cluster

=head1 SYNOPSIS

 ping.pl

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

	my @output = `ping -c 1 $hostname`;

	print grep { m/bytes from $hostname/ } @output;
} );

__END__

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2007-2010 by Al Tobey.

This is free software; you can redistribute it and/or modify it under the terms
of the Artistic License 2.0.  (Note that, unlike the Artistic License 1.0,
version 2.0 is GPL compatible by itself, hence there is no benefit to having an
Artistic 2.0 / GPL disjunction.)  See the file LICENSE for details.

=cut
