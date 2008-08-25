package TAP::Parser::Source::Perl;

use strict;
use Config;
use vars qw($VERSION @ISA);

use constant IS_WIN32 => ( $^O =~ /^(MS)?Win32$/ );
use constant IS_VMS => ( $^O eq 'VMS' );

use TAP::Parser::Source;
@ISA = 'TAP::Parser::Source';

=head1 NAME

TAP::Parser::Source::Perl - Stream Perl output

=head1 VERSION

Version 3.14

=cut

$VERSION = '3.14';

=head1 SYNOPSIS

  use TAP::Parser::Source::Perl;
  my $perl = TAP::Parser::Source::Perl->new;
  my $stream = $perl->source( [ $filename, @args ] )->get_stream;

=head1 DESCRIPTION

Takes a filename and hopefully returns a stream from it.  The filename should
be the name of a Perl program.

Note that this is a subclass of L<TAP::Parser::Source>.  See that module for
more methods.

=head1 METHODS

=head2 Class Methods

=head3 C<new>

 my $perl = TAP::Parser::Source::Perl->new;

Returns a new C<TAP::Parser::Source::Perl> object.

=head2 Instance Methods

=head3 C<source>

Getter/setter the name of the test program and any arguments it requires.

  my ($filename, @args) = @{ $perl->source };
  $perl->source( [ $filename, @args ] );

C<croak>s if C<$filename> could not be found.

=cut

sub source {
    my $self = shift;
    $self->_croak("Cannot find ($_[0][0])")
      if @_ && !-f $_[0][0];
    return $self->SUPER::source(@_);
}

=head3 C<switches>

  my $switches = $perl->switches;
  my @switches = $perl->switches;
  $perl->switches( \@switches );

Getter/setter for the additional switches to pass to the perl executable.  One
common switch would be to set an include directory:

  $perl->switches( ['-Ilib'] );

=cut

sub switches {
    my $self = shift;
    unless (@_) {
        return wantarray ? @{ $self->{switches} } : $self->{switches};
    }
    my $switches = shift;
    $self->{switches} = [@$switches];    # force a copy
    return $self;
}

##############################################################################

=head3 C<get_stream>

  my $stream = $source->get_stream($parser);

Returns a stream of the output generated by executing C<source>. Must be
passed an object that implements a C<make_iterator> method. Typically
this is a TAP::Parser instance.

=cut

sub get_stream {
    my ( $self, $factory ) = @_;

    my @extra_libs;

    my @switches = $self->_switches;
    my $path_sep = $Config{path_sep};
    my $path_pat = qr{$path_sep};

    # Nasty kludge. It might be nicer if we got the libs separately
    # although at least this way we find any -I switches that were
    # supplied other then as explicit libs.
    # We filter out any names containing colons because they will break
    # PERL5LIB
    my @libs;
    for ( grep { $_ !~ $path_pat } @switches ) {
        push @libs, $1 if / ^ ['"]? -I (.*?) ['"]? $ /x;
    }

    my $previous = $ENV{PERL5LIB};
    if ($previous) {
        push @libs, split( $path_pat, $previous );
    }

    my $setup = sub {
        if (@libs) {
            $ENV{PERL5LIB} = join( $path_sep, @libs );
        }
    };

    # Cargo culted from comments seen elsewhere about VMS / environment
    # variables. I don't know if this is actually necessary.
    my $teardown = sub {
        if ($previous) {
            $ENV{PERL5LIB} = $previous;
        }
        else {
            delete $ENV{PERL5LIB};
        }
    };

    # Taint mode ignores environment variables so we must retranslate
    # PERL5LIB as -I switches and place PERL5OPT on the command line
    # in order that it be seen.
    if ( grep { $_ eq "-T" || $_ eq "-t" } @switches ) {
        push @switches,
          $self->_libs2switches(
            split $path_pat,
            $ENV{PERL5LIB} || $ENV{PERLLIB} || ''
          );

        push @switches, $ENV{PERL5OPT} || ();
    }

    my @command = $self->_get_command_for_switches(@switches)
      or $self->_croak("No command found!");

    return $factory->make_iterator(
        {   command  => \@command,
            merge    => $self->merge,
            setup    => $setup,
            teardown => $teardown,
        }
    );
}

sub _get_command_for_switches {
    my $self     = shift;
    my @switches = @_;
    my ( $file, @args ) = @{ $self->source };
    my $command = $self->_get_perl;

# XXX we never need to quote if we treat the parts as atoms (except maybe vms)
#$file = qq["$file"] if ( $file =~ /\s/ ) && ( $file !~ /^".*"$/ );
    my @command = ( $command, @switches, $file, @args );
    return @command;
}

sub _get_command {
    my $self = shift;
    return $self->_get_command_for_switches( $self->_switches );
}

sub _libs2switches {
    my $self = shift;
    return map {"-I$_"} grep {$_} @_;
}

=head3 C<shebang>

Get the shebang line for a script file.

  my $shebang = TAP::Parser::Source::Perl->shebang( $some_script );

May be called as a class method

=cut

{

    # Global shebang cache.
    my %shebang_for;

    sub _read_shebang {
        my $file = shift;
        local *TEST;
        my $shebang;
        if ( open( TEST, $file ) ) {
            $shebang = <TEST>;
            close(TEST) or print "Can't close $file. $!\n";
        }
        else {
            print "Can't open $file. $!\n";
        }
        return $shebang;
    }

    sub shebang {
        my ( $class, $file ) = @_;
        unless ( exists $shebang_for{$file} ) {
            $shebang_for{$file} = _read_shebang($file);
        }
        return $shebang_for{$file};
    }
}

=head3 C<get_taint>

Decode any taint switches from a Perl shebang line.

  # $taint will be 't'
  my $taint = TAP::Parser::Source::Perl->get_taint( '#!/usr/bin/perl -t' );

  # $untaint will be undefined
  my $untaint = TAP::Parser::Source::Perl->get_taint( '#!/usr/bin/perl' );

=cut

sub get_taint {
    my ( $class, $shebang ) = @_;
    return
      unless defined $shebang
          && $shebang =~ /^#!.*\bperl.*\s-\w*([Tt]+)/;
    return $1;
}

sub _switches {
    my $self = shift;
    my ( $file, @args ) = @{ $self->source };
    my @switches = (
        $self->switches,
    );

    my $shebang = $self->shebang($file);
    return unless defined $shebang;

    my $taint = $self->get_taint($shebang);
    push @switches, "-$taint" if defined $taint;

    # Quote the argument if there's any whitespace in it, or if
    # we're VMS, since VMS requires all parms quoted.  Also, don't quote
    # it if it's already quoted.
    for (@switches) {
        $_ = qq["$_"] if ( ( /\s/ || IS_VMS ) && !/^".*"$/ );
    }

    return @switches;
}

sub _get_perl {
    my $self = shift;
    return $ENV{HARNESS_PERL} if defined $ENV{HARNESS_PERL};
    return Win32::GetShortPathName($^X) if IS_WIN32;
    return $^X;
}

1;

=head1 SUBCLASSING

Please see L<TAP::Parser/SUBCLASSING> for a subclassing overview.

=head2 Example

  package MyPerlSource;

  use strict;
  use vars '@ISA';

  use Carp qw( croak );
  use TAP::Parser::Source::Perl;

  @ISA = qw( TAP::Parser::Source::Perl );

  sub source {
      my ($self, $args) = @_;
      if ($args) {
	  $self->{file} = $args->[0];
	  return $self->SUPER::source($args);
      }
      return $self->SUPER::source;
  }

  # use the version of perl from the shebang line in the test file
  sub _get_perl {
      my $self = shift;
      if (my $shebang = $self->shebang( $self->{file} )) {
          $shebang =~ /^#!(.*\bperl.*?)(?:(?:\s)|(?:$))/;
	  return $1 if $1;
      }
      return $self->SUPER::_get_perl(@_);
  }

=head1 SEE ALSO

L<TAP::Object>,
L<TAP::Parser>,
L<TAP::Parser::Source>,

=cut
