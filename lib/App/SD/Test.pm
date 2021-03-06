package App::SD::Test;

use warnings;
use strict;

require Prophet::Test;
use Test::More;
use File::Spec;
use File::Temp ();
use Cwd qw/getcwd/;
use base qw/Exporter/;
our @EXPORT = qw(create_ticket_ok update_ticket_ok create_ticket_with_editor_ok create_ticket_comment_ok get_uuid_for_luid get_luid_for_uuid get_ticket_info);
delete $ENV{'PROPHET_APP_CONFIG'};
$ENV{'EDITOR'} = '/bin/true';

our ($A, $B, $C, $D);

BEGIN {
    # create a blank config file so per-user configs don't break tests
    my $tmp_config = File::Temp->new( UNLINK => 0 );
    print $tmp_config '';
    close $tmp_config;
    print "setting SD_CONFIG to " . $tmp_config->filename . "\n";
    $ENV{'SD_CONFIG'} = $tmp_config->filename;
    $ENV{'PROPHET_EMAIL'} = 'nobody@example.com';
}

=head2 create_ticket_ok ARGS

Creates a new ticket, passing ARGS along to the creation command (after the
props separator).

Returns a list of the luid and uuid of the newly created ticket.

=cut

sub create_ticket_ok {
    my @args = (@_);
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    Prophet::Test::run_output_matches( 'sd', [ 'ticket', 'create', '--', @args ],
        [qr/Created ticket (.*?)(?{ $A = $1})\s+\((.*)(?{ $B = $2 })\)/]
    );

    my ( $uuid, $luid ) =($B,$A);
    return ( $luid, $uuid );
}

=head2 update_ticket_ok ID ARGS

Updates the ticket #ID, passing ARGS along to the update command.

Returns nothing interesting.

=cut

sub update_ticket_ok {
    my ($id, @args) = (@_);
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    Prophet::Test::run_output_matches( 'sd', [ 'ticket', 'update', $id, '--', @args ],
        [qr/ticket \d+\s+\([^)]*\)\s+updated\./i]
    );
}

=head2 create_ticket_comment_ok ARGS

Creates a new ticket comment, passing ARGS along to the creation command.

Returns a list of the luid and uuid of the newly created comment.

=cut

sub create_ticket_comment_ok {
    my @args = (@_);
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    Prophet::Test::run_output_matches(
        'sd',
        [ 'ticket', 'comment', 'create', @args ],
        [qr/Created comment (.*?)(?{ $A = $1})\s+\((.*)(?{ $B = $2 })\)/]
    );
    my ( $uuid, $luid ) = ($B, $A);

    return ( $luid, $uuid );
}

=head2 create_ticket_ok luid

Takes a LUID and returns the corresponding UUID.

Returns undef if none can be found.

=cut

sub get_uuid_for_luid {
        my $luid = shift;
    my ($ok, $out, $err) =  Prophet::Test::run_script( 'sd', [ 'ticket', 'show', '--batch', '--id', $luid ]);
    if ($out =~ /^id: \d+ \((.*)\)/m) {
            return $1;
    }
    return undef;
}

=head2 get_luid_for_uuid UUID

Takes a UUID and returns the corresponding LUID.

Returns undef if none can be found.

=cut

sub get_luid_for_uuid {
        my $uuid = shift;
    my ($ok, $out, $err) =  Prophet::Test::run_script( 'sd', [ 'ticket', 'show', '--batch', '--id', $uuid ]);
    if ($out =~ /^id: (\d+)/m) {
            return $1;
    }
    return undef;
}

=head2 create_ticket_with_editor_ok [ '--verbose' ... ]

Creates a ticket and comment at the same time using a spawned editor.  It's
expected that C<$ENV{VISUAL}> has been frobbed into something non-interactive,
or this test will just hang forever. Any extra arguments passed in will be
passed on to sd ticket create.

Returns a list of the ticket luid, ticket uuid, comment luid, and comment uuid.

=cut

sub create_ticket_with_editor_ok {
    my @extra_args = @_;

    local $Test::Builder::Level = $Test::Builder::Level + 1;
    Prophet::Test::run_output_matches( 'sd', [ 'ticket', 'create', @extra_args ],
        [qr/Created ticket (.*?)(?{ $A = $1})\s+\((.*)(?{ $B = $2 })\)/,
        qr/Created comment (.*?)(?{ $C = $1})\s+\((.*)(?{ $D = $2 })\)/]
    );

    my ( $ticket_uuid, $ticket_luid, $comment_uuid, $comment_luid )=  ($B,$A,$D,$C);
    return ( $ticket_luid, $ticket_uuid, $comment_luid, $comment_uuid );
}

=head2 update_ticket_with_editor_ok TICKET_LUID, TICKET_UUID [ '--verbose' ]

Updates the ticket given by TICKET_UUID using a spawned editor. It's
expected that C<$ENV{VISUAL}> has been frobbed into something non-interactive,
or this test will just hang forever. Any extra arguments passed in will
be passed on to sd ticket update.

Returns the luid and uuid of the comment created during the update (both will
be undef if none is created).

=cut

sub update_ticket_with_editor_ok {
    my $self = shift;
    my $ticket_luid = shift;
    my $ticket_uuid = shift;
    my @extra_args = @_;

    local $Test::Builder::Level = $Test::Builder::Level + 1;
    Prophet::Test::run_output_matches( 'sd', [ 'ticket', 'update', $ticket_uuid,
                                               @extra_args ],
        [ qr/Updated ticket (.*?)\s+\((.*)\)/,
          qr/Created comment (.*?)(?{ $A = $1 })\s+\((.*)(?{ $B = $2 })\)/ ]
    );

    my ($comment_luid, $comment_uuid) = ($A, $B);
    return ( $comment_luid, $comment_uuid );
}

=head2 update_ticket_comment_with_editor_ok COMMENT_LUID, COMMENT_UUID

Updates the ticket comment given by COMMENT_UUID using a spawned editor. It's
expected that C<$ENV{VISUAL}> has been frobbed into something non-interactive,
or this test will just hang forever.

=cut

sub update_ticket_comment_with_editor_ok {
    my $self = shift;
    my ($comment_luid, $comment_uuid) = @_;

    local $Test::Builder::Level = $Test::Builder::Level + 1;
    Prophet::Test::run_output_matches( 'sd',
        [ 'ticket', 'comment', 'update', $comment_uuid ],
        [ 'Updated comment '.$comment_luid . ' ('. $comment_uuid .')']
    );
}

=head2 get_ticket_info LUID/UUID

Returns a hash reference with information about ticket.

=cut

sub get_ticket_info {
    my $id = shift;
    my ($ok, $out, $err) =  Prophet::Test::run_script( 'sd', [qw(ticket show --batch --verbose --id), $id ]);

    my @lines = split /\n/, $out;

    my %res;
    my $section = '';
    while ( defined( $_ = shift @lines ) ) {
        if ( /^= ([A-Z]+)\s*$/ ) {
            $section = lc $1;
            next;
        }
        next unless $section;

        if ( $section eq 'metadata' ) {
            next unless /^(\w+):\s*(.*?)\s*$/;
            $res{$section}{$1} = $2;
        }
    }

    if ( $res{'metadata'}{'id'} ) {
        @{ $res{'metadata'} }{'luid', 'uuid'} = (
            $res{'metadata'}{'id'} =~ /^(\d+)\s+\((.*?)\)\s*$/
        );
    }

    return \%res;
}

=head2 set_editor SCRIPT

Sets the editor that Proc::InvokeEditor uses (which is used for nicer ticket
and comment creation / update, etc.).

This should be a non-interactive script found in F<t/scripts>.

=cut

sub set_editor {
    my ($self, $script) = @_;

    delete $ENV{'VISUAL'};       # Proc::InvokeEditor checks this first
    $ENV{'EDITOR'} = "$^X " . File::Spec->catfile(getcwd(), 't', 'scripts', $script);
    diag "export EDITOR=" . $ENV{'EDITOR'} . "\n";
}

=head2 write_to_file FILENAME DATA

Takes the string given in DATA and writes it to the file whose name is given
by FILENAME.

=cut

sub write_to_file {
    my ($self, $filename, $data) = @_;

    open FH, '>', $filename;
    print FH $data;
    close FH;
}

1;
