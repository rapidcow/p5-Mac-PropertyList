use v5.10;

package Mac::PropertyList::ReadBinary;
use strict;
use warnings;

use Carp;
use Config ();
use Data::Dumper;
use Encode            qw(decode);
use Mac::PropertyList;
use Math::BigInt;
use POSIX             qw(SEEK_END SEEK_SET);

our $VERSION = '1.603_02';

my $Debug = $ENV{PLIST_DEBUG} || 0;

use constant {
    haveUnpack64 => ( eval { unpack('Q>', "\x10\x01\0\0\0\0\0\x0B") eq '1153202979583557643' } ? 1 : 0 ),
};

__PACKAGE__->_run( @ARGV ) unless caller;

=encoding utf8

=head1 NAME

Mac::PropertyList::ReadBinary - read binary property list files

=head1 SYNOPSIS

	# use directly
	use Mac::PropertyList::ReadBinary;

	my $parser = Mac::PropertyList::ReadBinary->new( $file );

	my $plist = $parser->plist;

	# use indirectly, automatically selects right reader
	use Mac::PropertyList;

	my $plist = parse_plist_file( $file );

=head1 DESCRIPTION

This module is a low-level interface to the Mac OS X Property List
(plist) format. You probably shouldn't use this in
applications—build interfaces on top of this so you don't have to
put all the heinous multi-level object stuff where people have to look
at it.

You can parse a plist file and get back a data structure. You can take
that data structure and get back the plist as XML (but not binary
yet). If you want to change the structure inbetween that's your
business. :)

See L<Mac::PropertyList> for more details.

=head2 Methods

=over 4

=item new( FILENAME | SCALAR_REF | FILEHANDLE )

Opens the data source, doing the right thing for filenames,
scalar references, or a filehandle.

=cut

sub new {
	my( $class, $source ) = @_;

	my $self = bless { source => $source }, $class;

	$self->_read;

	$self;
	}

sub _source          { $_[0]->{source}             }
sub _fh              { $_[0]->{fh}                 }
sub _trailer         { $_[0]->{trailer}            }
sub _offsets         { $_[0]->{offsets}            }
sub _object_ref_size { $_[0]->_trailer->{ref_size} }

=item plist

Returns the C<Mac::PropertyList> data structure.

=cut

sub plist            { $_[0]->{parsed}             }

sub _object_size {
	$_[0]->_trailer->{object_count} * $_[0]->_trailer->{offset_size}
	}

# _read_fh and _seek_fh are autodie-wrappers of read() and seek().
# _seek_fh also tell()s, though it shouldn't impose more restrictions
# than the way we already expect the filehandle to be seekable.
#
# _curpos and _length track the current offset and the file size.
# They are temporary states deleted upon parse completion.

sub _read_fh {
	my( $self, $try_to_read, $what ) = @_;
	unless ($try_to_read <= $self->{_length} - $self->{_curpos}) {
		croak( "reading $what extends beyond EOF" );
		}

	my $buffer;
	my $really_read = read( $self->_fh, $buffer, $try_to_read );
	croak( "reading $what failed! $!" ) unless defined $really_read;
	unless ($really_read == $try_to_read) {
		croak( "short read while reading $what "
		. "(want $try_to_read, read $really_read)" );
		}

	$self->{_curpos} += $really_read;
	$buffer;
	}

sub _seek_fh {
	my( $self, $pos, $whence, $what ) = @_;
	my $seek_ok = seek( $self->_fh, $pos, $whence );
	croak( "seeking to $what failed! $!" ) unless $seek_ok;
	$self->{_curpos} = $whence == SEEK_SET ? $pos : do {
		my $cur = tell( $self->_fh );
		croak( "telling from $what failed: $!" ) if $cur == -1;
		$cur;
		};
	}

sub _read {
	my( $self, $thingy ) = @_;

	$self->{fh} = $self->_get_filehandle;

	$self->{_length} = $self->_seek_fh( 0, SEEK_END, "EOF" );

	$self->_read_plist_trailer;

	$self->_get_offset_table;

    my $top = $self->_read_object_at_offset( $self->_trailer->{top_object} );

	delete @{$self}{qw( _curpos _length )};

    $self->{parsed} = $top;
	}

sub _get_filehandle {
	my( $self, $thingy ) = @_;

	my $fh;

	if( ! ref $self->_source ) { # filename
		open $fh, "<", $self->_source
			or die "Could not open [@{[$self->_source]}]! $!";
		}
	elsif( ref $self->_source eq ref \ ''  ) { # scalar ref
		open $fh, "<", $self->_source or croak "Could not open file! $!";
		}
	elsif( ref $self->_source ) { # filehandle
		$fh = $self->_source;
		}
	else {
		croak( 'No source to read from!' );
		}

	$fh;
	}

sub _read_plist_trailer {
	my $self = shift;

	$self->_seek_fh( $self->{_length} - 32, SEEK_SET, "trailer" );

	my $buffer = $self->_read_fh( 32, "trailer" );
	my %hash;

	@hash{ qw(
		offset_size       ref_size
		object_count_high object_count
		top_object_high   top_object
		table_offset_high table_offset
	) }
		= unpack "x6 C C ("
		. ( haveUnpack64 ? "a0 Q>" : "NN" )
		. ")3", $buffer;

	if( my( $bad_key ) = grep { $hash{$_} && s/_high$// } keys %hash)
		{
		croak( "trailer $bad_key too large" );
		}

	delete @hash{ grep { /_high$/ } keys %hash };

	$self->{trailer} = \%hash;
	}

sub _get_offset_table {
	my $self = shift;

	my $try_to_read = $self->_object_size;

    $self->_seek_fh( $self->_trailer->{table_offset}, SEEK_SET, "offset table" );

    my $raw_offset_table = $self->_read_fh( $try_to_read, "offset table" );

    my @offsets = _unpack_int_array(
	$self->_trailer->{offset_size},
	$raw_offset_table);

	$self->{offsets} = \@offsets;
	}

{

my %native_format = (
	1 => "C*", 2 => "n*", 4 => "N*",
	haveUnpack64 ? (8 => "Q>*") : ()
	);

# This function unpacks int for file offset and object ref index.
# To err on the side of caution, limit this to integers represent-
# able natively as IV/UV, even if lseek may accept larger offsets.

sub _unpack_int_array {
	my( $size, $buffer ) = @_;
	$size > 0 or croak "integer of width <$size> is invalid";
	if( exists $native_format{$size} ) {
		unpack $native_format{$size}, $buffer;
		}
	# Deal with weird widths, like 3,5,6,7...
	elsif( $size <= $Config::Config{ivsize} ) {
		map { hex } unpack "(H@{[$size << 1]})*", $buffer;
		}
	else {
		croak( "integer of width <$size> too wide" );
		}
	}

}

sub _read_object_refs {
	my( $self, $length ) = @_;
	my $try_to_read = $length * $self->_object_ref_size;

	my $buffer = $self->_read_fh( $try_to_read, "object refs" );
	_unpack_int_array( $self->_object_ref_size, $buffer );
	}

sub _read_object_at_offset {
	my( $self, $offset ) = @_;

    $self->_seek_fh( ${ $self->_offsets }[$offset], SEEK_SET );

    $self->_read_object;
	}

# # # # # # # # # # # # # #

BEGIN {

my %singletons = (
    0 => undef,
    8 => Mac::PropertyList::false->new(),
    9 => Mac::PropertyList::true->new(),

    # 15 is also defined (as "fill") in the comments to Apple's
    # implementation in CFBinaryPList.c but Apple's actual code has no
    # support for it at all, either reading or writing, so it's
    # probably not important to implement.
	);

my $type_readers = {
	0 => sub { # the odd balls
		my( $self, $length ) = @_;

		return $singletons{ $length } if exists $singletons{ $length };

		croak ( sprintf "Unknown type byte %02X\n", $length );
    	},

	1 => sub { # integers
		my( $self, $power_of_2 ) = @_;

		croak "Integer with <$power_of_2> bytes is not supported" if $power_of_2 > 4;

		my $byte_length = 1 << $power_of_2;

		my $buffer = $self->_read_fh( $byte_length, "integer" );

		my @formats = qw( C n N NN NNNN );
		my @values = unpack $formats[$power_of_2], $buffer;

		if( $power_of_2 == 3 ) { # 64 bits
			my( $high, $low ) = @values;

			my $b = Math::BigInt->new($high)->blsft(32)->bior($low);
			if( $b->bcmp(Math::BigInt->new(2)->bpow(63)) >= 0) {
				$b -= Math::BigInt->new(2)->bpow(64);
				}

			@values = ( $b );
			}
		elsif( $power_of_2 == 4 ) { # 128 bits
		    # 128 bits aren't part of the public API, but apparently
		    # they are out there.
			my( $highest, $higher, $high, $low ) = @values;
			my $b = Math::BigInt
				->new($highest)
				->blsft(32)->bior($higher)
				->blsft(32)->bior($high)
				->blsft(32)->bior($low);

			if( $b->bcmp(Math::BigInt->new(2)->bpow(127)) >= 0) {
				$b -= Math::BigInt->new(2)->bpow(128);
				}

			@values = ( $b );
			}

		return Mac::PropertyList::integer->new( $values[0] );
		},

	2 => sub { # reals
		my( $self, $length ) = @_;
		croak "Real > 8 bytes" if $length > 3;
		croak "Bad length [$length]" if $length < 2;

		my $byte_length = 1 << $length;

		my $buffer = $self->_read_fh( $byte_length, "real" );

		my @formats = qw( a a f> d> );
		my @values = unpack $formats[$length], $buffer;

		return Mac::PropertyList::real->new( $values[0] );
		},

	3 => sub { # date
		my( $self, $length ) = @_;
		croak "Date != 8 bytes" if $length != 3;
		my $byte_length = 1 << $length;

		my $buffer = $self->_read_fh( $byte_length, "date" );

		my @values = unpack 'd>', $buffer;

		$self->{MLen} += 9;

		my $adjusted_time = POSIX::strftime(
			"%Y-%m-%dT%H:%M:%SZ",
			gmtime( 978307200 + $values[0])
			);

		return Mac::PropertyList::date->new( $adjusted_time );
		},

	4 => sub { # binary data
		my( $self, $length ) = @_;

		my $buffer = $self->_read_fh( $length, "binary data" );

		return Mac::PropertyList::data->new( $buffer );
		},

	5 => sub { # utf8 string
		my( $self, $length ) = @_;

		my $buffer = $self->_read_fh( $length, "utf8 string" );

		$buffer = Encode::decode( 'ascii', $buffer );

		return Mac::PropertyList::string->new( $buffer );
		},

	6 => sub { # unicode string
		my( $self, $length ) = @_;

		my $buffer = $self->_read_fh( 2 * $length, "unicode string" );

		$buffer = Encode::decode( "UTF-16BE", $buffer );

		return Mac::PropertyList::ustring->new( $buffer );
		},

	8 => sub { # UIDs
		my( $self, $length ) = @_;

		my $byte_length = $length + 1;

		my $buffer = $self->_read_fh( $byte_length, "UID" );

		my $value = unpack 'H*', $buffer;

		return Mac::PropertyList::uid->new( $value );
		},

	a => sub { # array
		my( $self, $elements ) = @_;

		my @objects = $self->_read_object_refs($elements);

		my @array =
			map { $self->_read_object_at_offset( $objects[$_] ) }
			0 .. $elements - 1;

		return Mac::PropertyList::array->new( \@array );
		},

	d => sub { # dictionary
		my( $self, $length ) = @_;

		my @key_indices = $self->_read_object_refs($length);
		my @objects = $self->_read_object_refs($length);

		my %dict = map {
			my $key   = $self->_read_object_at_offset($key_indices[$_])->value;
			my $value = $self->_read_object_at_offset($objects[$_]);
			( $key, $value );
			} 0 .. $length - 1;

		return Mac::PropertyList::dict->new( \%dict );
		},
	};

sub _read_object {
	my $self = shift;
    my $buffer = $self->_read_fh( 1, "type byte" );

    my $length = unpack( "C*", $buffer ) & 0x0F;
    $buffer    = unpack "H*", $buffer;
    my $type   = substr $buffer, 0, 1;

	$length = $self->_read_object->value if $type ne "0" && $length == 15;

	my $sub = $type_readers->{ $type };
	my $result = eval { $sub->( $self, $length ) };
	croak "$@" if $@;

    return $result;
	}

}

=back

=head1 SEE ALSO

Some of the ideas are cribbed from CFBinaryPList.c

	http://opensource.apple.com/source/CF/CF-550/CFBinaryPList.c

=head1 SOURCE AVAILABILITY

This project is in Github:

	https://github.com/briandfoy/mac-propertylist.git

=head1 CREDITS

=head1 AUTHOR

brian d foy, C<< <briandfoy@pobox.com> >>

Tom Wyant added support for UID types.

=head1 COPYRIGHT AND LICENSE

Copyright © 2004-2026, brian d foy <briandfoy@pobox.com>. All rights reserved.

This program is free software; you can redistribute it and/or modify
it under the terms of the Artistic License 2.0.

=cut

"See why 1984 won't be like 1984";
