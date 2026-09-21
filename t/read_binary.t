#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

BEGIN {
    # Silence 'wide character' warning in Unicode test
    binmode STDOUT, ':encoding(utf-8)';
}

use Config ();
use Test::More;

=encoding utf8

=head1 NAME

read_binary.t

=head1 SYNOPSIS

        # run all the tests
        % perl Makefile.PL
        % make test

        # run all the tests
        % prove

        # run a single test
        % perl -Ilib t/read_binary.t

        # run a single test
        % prove t/read_binary.t

=head1 AUTHORS

Original author: brian d foy C<< <briandfoy@pobox.com> >>

Contributors:

=over 4

=item Wim Lewis C<< <wiml@hhhh.org> >>

=item Tom Wyant C<< <wyant@cpan.org> >>

=back

=head1 SOURCE

This file was originally in https://github.com/briandfoy/mac-propertylist

=head1 COPYRIGHT

Copyright © 2002-2026, brian d foy, C<< <briandfoy@pobox.com> >>

=head1 LICENSE

This file is licenses under the Artistic License 2.0. You should have
received a copy of this license with this distribution.

=cut

use File::Spec::Functions;

my $class = 'Mac::PropertyList::ReadBinary';
( my $base_class = $class ) =~ s/(.+)::.*/$1/;
my @methods = qw( new plist );

my $dict_type  = join '::', $base_class, 'dict';
my $array_type = join '::', $base_class, 'array';
my $uid_type   = join '::', $base_class, 'uid';
my $data_type  = join '::', $base_class, 'data';
my $date_type  = join '::', $base_class, 'date';

use_ok( $class ) or BAIL_OUT( "$class did not compile\n" );
can_ok( $class, @methods );

my $test_file = catfile( qw( plists the_perl_review.abcdp ) );
ok( -e $test_file, "Test file for binary plist is there" );

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Use it directly
{
my $parser = $class->new( $test_file );
isa_ok( $parser, $class );

my $plist = $parser->plist;
isa_ok( $plist, "${base_class}::dict" );

my %keys_hash = map { $_, 1 } $plist->keys;

foreach my $key ( qw(UID URLs Address Organization) )
        {
        ok( exists $keys_hash{$key}, "$key exists" );
        }

is(
        $plist->value( 'Organization' ),
        'The Perl Review',
        'Organization returns the right value'
        );

isa_ok( $plist->{'Creation'}, $date_type );
is( $plist->{'Creation'}->value, '2007-11-14T02:19:03Z', 'Creation date has the right value' );

is_deeply(
        $plist->{'Phone'}->as_perl,
        {
                'identifiers' => [
                    'DCBE4C18-EC2E-457F-A594-99A10257AB37',
                    'CBE21CFF-0EF2-4975-98E6-84FCA75202BA'
                ],
                'labels' => [
                    '_$!<Mobile>!$_',
                    '_$!<WorkFAX>!$_'
                ],
                'primary' => 'DCBE4C18-EC2E-457F-A594-99A10257AB37',
                'values' => [
                    '(312) 492-4632',
                    '866 750-7099'
                ]
        },
        'nested arrays and dicts return the right value'
        );

}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Use it indirectly
{
use_ok( $base_class, qw(parse_plist_file) );

my $plist = parse_plist_file( $test_file );
isa_ok( $plist, $dict_type );

my %keys_hash = map { $_, 1 } $plist->keys;

foreach my $key ( qw(UID URLs Address Organization) )
        {
        ok( exists $keys_hash{$key}, "$key exists" );
        }

is(
        $plist->value( 'Organization' ),
        'The Perl Review',
        'Organization returns the right value'
        );

}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Test with real and data
{
use_ok( 'Mac::PropertyList', qw(parse_plist_file) );

my $test_file = catfile( qw( plists binary.plist ) );
my $plist = parse_plist_file( $test_file );
isa_ok( $plist, $dict_type );

is(
        $plist->value( 'PositiveInteger' ),
        '135',
        'PositiveInteger returns the right value'
        );

is(
        $plist->value( 'NegativeInteger' ),
        '-246',
        'NegativeInteger returns the right value'
        );

my $π = $plist->value( 'Pi' );
my $Δ = abs( 3.14159 - $π ); # possible floating point error
my $ε = 1e-4;

ok(
        $Δ < $ε,
        'π returns the right value, within ε'
        );

isa_ok( $plist->{'Data'}, $data_type );
is( $plist->value( 'Data' ), "\x01\x50\x01\x15", "Data returns the right value" );

}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Test with various width integers, booleans, unusual strings
{
my $test_file_2 = catfile( qw( plists binary2.plist ) );
my $plist = parse_plist_file( $test_file_2 );

isa_ok( $plist, $array_type );
my(@values) = $plist->value;
my(@want) = (
    [ integer   => 1280 ],
    [ integer   => 2752512 ],
    [ integer   => 2147483649 ],
    [ integer   => 4294967295 ],
    [ integer   => bigint('4294967296') ],
    [ integer   => bigint('9223372036854775807') ],
    [ integer   => -1 ],
    [ integer   => -255 ],
    [ integer   => -256 ],
    [ integer   => -65536 ],
    [ integer   => bigint('-4294967296') ],
    [ integer   => bigint('-9223372036854775808') ],
    [ true      => 'true' ],
    [ false     => 'false' ],
    [ string    => 'Entities: & and &amp;' ],
    [ ustring   => 'Unicode: π≠2 Entities: & and &amp;' ],
    [ ustring   => "Unicode Supplementary: \x{1203C}, \x{1F06B}." ],
);
is( scalar @values, scalar @want, 'right number of elements in array' );

# The characters in the Supplementary string are CUNEIFORM SIGN ASH
# OVER ASH OVER ASH and DOMINO TILE VERICAL 1 1.  They were entered
# in utf8 into an xml plist, then converted to bplist format by plutil
# on MacOSX10.6.8.

for my $index (0 .. $#want) {
    my ( $type, $expect ) = @{ $want[$index] };
    my $value = $values[$index];
    isa_ok( $value, "${base_class}::$type" );
    is( scalar $value->value, $expect,
        "$type at index $index has right value" );
}
}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Test UIDs
{
    note 'Testing UID input';

    my $test_file = catfile( qw{ plists binary_uids.plist } );
    my $plist = parse_plist_file( $test_file );

    isa_ok( $plist, $array_type );

    my @expect = qw{ 01 2a 04d2 0074cbb1 };
    my @values = $plist->value();
    is( scalar @values, scalar @expect, 'Right number of elements in array' );

    for my $index ( 0 .. $#expect ) {
        isa_ok( $values[$index], $uid_type );
        is( $values[$index]->value, $expect[$index],
            "uid at index $index has right value" );
    }
}

# # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# Test with object refs of various width
subtest 'various width object refs' => sub {
	my $iz = $Config::Config{ivsize};
	plan tests => 1 + (4 * $iz * $iz);

	use_ok( $base_class, 'parse_plist' );
	my $expect_key = 'key',
	my @expect_array = ( 74, 97, 80, 72 );

	foreach my $rz ( 1 .. $iz ) { foreach my $oz ( 1 .. $iz ) {
SKIP:		{
		my $test_data = various_width_fixture(
			ob_ref_size => $rz,
			offset_size => $oz,
		);
		my $plist = parse_plist( $test_data );

		isa_ok( $plist, $dict_type ) or skip( "type mismatch", 3 );
		ok( grep { $_ eq $expect_key } $plist->keys, "dict has $expect_key" );

		my $array = $plist->value('key');
		isa_ok( $array, $array_type ) or skip( "type mismatch", 3 );
		is_deeply( [ map { $_->value } @{$array} ], \@expect_array );
		}
	} }
};

done_testing();

sub bigint { return Math::BigInt->new( $_[0] ) };

sub various_width_fixture {
	my (%o) = @_;

	my $rz = $o{ob_ref_size};
	my $oz = $o{offset_size};

	my $data = 'bplist00';
	my $top_object = 0;
	my @objects = (
		# 0: Dictionary ( 1 => 2 )
		"\xD1" . pack("(x@{[$rz - 1]} C)2", 1 => 2),

		# 1: String "key"
		"\x53key",

		# 2: Array ( 3, 4, 5, 6 )
		"\xA4" . pack("(x@{[$rz - 1]} C)4", 3 .. 6),

		# 3: Integers
		map { "\x10" . pack('C', $_) } (74, 97, 80, 72),
		);

	my @offsets;
	foreach my $object (@objects) {
		push @offsets, length($data);
		$data .= $object;
		}

	my $table_start = length($data);
	foreach my $offset (@offsets) {
		$data .= pack("x@{[$oz - 1]} C", $offset);
		}

	$data .= pack("x6 C C (x4 N)3",
		$oz, $rz, scalar(@objects), $top_object, $table_start);
	return $data;
	}
