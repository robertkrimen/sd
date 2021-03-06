package App::SD::Replica::trac::PullEncoder;
use Any::Moose;
extends 'App::SD::ForeignReplica::PullEncoder';

use Params::Validate qw(:all);
use Memoize;
use Time::Progress;
use DateTime;

has sync_source => (
    isa => 'App::SD::Replica::trac',
    is  => 'rw'
);

sub run {
    my $self = shift;
    my %args = validate(
        @_,
        {   after    => 1,
            callback => 1,
        }
    );
    $self->sync_source->log('Finding matching tickets');
    my @tickets = @{ $self->find_matching_tickets() };

    if ( @tickets == 0 ) {
        $self->sync_source->log("No tickets found.");
        return;
    }

    my @changesets;
    my $counter = 0;
    $self->sync_source->log("Discovering ticket history");
    my $progress = Time::Progress->new();
    $progress->attr( max => $#tickets );
    local $| = 1;

    my $last_modified_date;

    for my $ticket (@tickets) {
        print $progress->report( "%30b %p Est: %E\r", $counter );
        $self->sync_source->log(
            "Fetching ticket @{[$ticket->id]} - " . ++$counter . " of " . scalar @tickets );

        $last_modified_date = $ticket->last_modified
            if ( !$last_modified_date || $ticket->last_modified > $last_modified_date );

        my $ticket_data         = $self->_translate_final_ticket_state($ticket);
        my $ticket_initial_data = {%$ticket_data};
        my $txns                = $self->skip_previously_seen_transactions(
            ticket       => $ticket,
            transactions => $ticket->history->entries,
            starting_transaction => $self->sync_source->app_handle->handle->last_changeset_from_source(
 $self->sync_source->uuid_for_remote_id( $ticket->id )
        )

        );
    
        # Walk transactions newest to oldest.
        for my $txn ( sort { $b->date <=> $a->date } @$txns ) {
            $self->sync_source->log( $ticket->id . " - Transcoding transaction  @{[$txn->date]} " );

            # the changesets are older than the ones that came before, so they goes first
            unshift @changesets,
                grep {defined} $self->transcode_one_txn( $txn, $ticket_initial_data, $ticket_data );
        }

    }

    $args{callback}->($_) for @changesets;
    $self->sync_source->record_upstream_last_modified_date($last_modified_date);
}


sub _translate_final_ticket_state {
    my $self          = shift;
    my $ticket_object = shift;
    
    my $content = $ticket_object->description;
    my $ticket_data = {

        $self->sync_source->uuid . '-id' => $ticket_object->id,

        owner => ( $ticket_object->owner || undef ),
        type => ($ticket_object->type || undef),
        created     => ( $ticket_object->created->ymd . " " . $ticket_object->created->hms ),
        reporter    => ( $ticket_object->reporter || undef ),
        status      => $self->translate_status( $ticket_object->status ),
        summary     => ( $ticket_object->summary || undef ),
        description => ( $content||undef),
        tags        => ( $ticket_object->keywords || undef ),
        component   => ( $ticket_object->component || undef ),
        milestone   => ( $ticket_object->milestone || undef ),
        priority    => ( $ticket_object->priority || undef ),
        severity    => ( $ticket_object->severity || undef ),
        cc          => ( $ticket_object->cc || undef ),
    };




    # delete undefined and empty fields
    delete $ticket_data->{$_}
        for grep !defined $ticket_data->{$_} || $ticket_data->{$_} eq '', keys %$ticket_data;

    return $ticket_data;
}

=head2 find_matching_tickets QUERY

Returns a Trac::TicketSearch collection for all tickets found matching your QUERY hash.

=cut

sub find_matching_tickets {
    my $self  = shift;
    my %query = (@_);
   my $last_changeset_seen_dt =   $self->_only_pull_tickets_modified_after();
    $self->sync_source->log("Searching for tickets");

    my $search = Net::Trac::TicketSearch->new( connection => $self->sync_source->trac, limit => 9999 );
    $search->query(%query);
    my @results = @{$search->results};
     $self->sync_source->log("Trimming things after our last pull");
    if ($last_changeset_seen_dt) {
        # >= is wasteful but may catch race conditions
        @results = grep {$_->last_modified >= $last_changeset_seen_dt} @results; 
    }
    return \@results;
}

=head2 skip_previously_seen_transactions { ticket => $id, starting_transaction => $num, transactions => \@txns  }

Returns a reference to an array of all transactions (as hashes) on ticket $id after transaction $num.

=cut

sub skip_previously_seen_transactions {
    my $self = shift;
    my %args = validate( @_, { ticket => 1, transactions => 1, starting_transaction => 0 } );
    my @txns;

    for my $txn ( sort @{ $args{transactions} } ) {
        my $txn_date = $txn->date->epoch;

        # Skip things we know we've already pulled
        next if $txn_date < ( $args{'starting_transaction'} ||0 );
        # Skip things we've pushed
        next if ($self->sync_source->foreign_transaction_originated_locally($txn_date, $args{'ticket'}->id) );

        # ok. it didn't originate locally. we might want to integrate it
        push @txns, $txn;
    }
    $self->sync_source->log('Done looking at pulled txns');
    return \@txns;
}

sub build_initial_ticket_state {
    my $self          = shift;
    my $final_state   = shift;
    my $ticket_object = shift;

    my %initial_state = %{$final_state};

    for my $txn ( reverse @{ $ticket_object->history->entries } ) {
        for my $pc ( values %{ $txn->prop_changes } ) {
            unless ( $initial_state{ $pc->property } eq $pc->new_value ) {
                warn "I was expecting "
                    . $pc->property
                    . " to be "
                    . $pc->new_value
                    . " but it was actually "
                    . $initial_state{ $pc->property };
            }
            $initial_state{ $pc->property } = $pc->old_value;

        }
    }
    return \%initial_state;
}

sub transcode_create_txn {
    my $self        = shift;
    my $txn         = shift;
    my $create_data = shift;
    my $final_data = shift;
    my $ticket      = $txn->ticket;
             # this sequence_no only works because trac tickets only allow one update 
             # per ticket per second.
             # we decrement by 1 on the off chance that someone created and 
             # updated the ticket in the first second
    my $changeset = Prophet::ChangeSet->new(
        {   original_source_uuid => $self->sync_source->uuid_for_remote_id( $ticket->id ),
            original_sequence_no => ( $ticket->created->epoch-1),
            creator => $self->resolve_user_id_to( email_address => $create_data->{reporter} ),
            created => $ticket->created->ymd ." ".$ticket->created->hms
        }
    );

    my $change = Prophet::Change->new(
        {   record_type => 'ticket',
            record_uuid => $self->sync_source->uuid_for_remote_id( $ticket->id ),
            change_type => 'add_file'
        }
    );

    for my $prop ( keys %$create_data ) {
        next unless defined $create_data->{$prop};
        next if $prop =~ /^(?:patch)$/;
        $change->add_prop_change( name => $prop, old => '', new => $create_data->{$prop} );
    }

    $changeset->add_change( { change => $change } );
    return $changeset;
}

            # we might get return:
            # 0 changesets if it was a null txn
            # 1 changeset if it was a normal txn
            # 2 changesets if we needed to to some magic fixups.
sub transcode_one_txn {
    my ( $self, $txn, $ticket, $ticket_final ) = (@_);


    if ($txn->is_create) {
        return $self->transcode_create_txn($txn,$ticket,$ticket_final);
    }

    my $ticket_uuid = $self->sync_source->uuid_for_remote_id( $ticket->{ $self->sync_source->uuid . '-id' } );

    my $changeset = Prophet::ChangeSet->new(
        {   original_source_uuid => $ticket_uuid,
            original_sequence_no => $txn->date->epoch,    # see comment on ticket
                                                          # create changeset
            creator => $self->resolve_user_id_to( email_address => $txn->author ),
            created => $txn->date->ymd . " " . $txn->date->hms
        }
    );

    my $change = Prophet::Change->new(
        {   record_type => 'ticket',
            record_uuid => $ticket_uuid,
            change_type => 'update_file'
        }
    );

#    warn "right here, we need to deal with changed data that trac failed to record";

    foreach my $prop_change ( values %{ $txn->prop_changes || {} } ) {
        my $new      = $prop_change->new_value;
        my $old      = $prop_change->old_value;
        my $property = $prop_change->property;
        next if $property =~ /^(?:patch)$/;

        $old = undef if ( $old eq '' );
        $new = undef if ( $new eq '' );

        if (!exists $ticket_final->{$property}) {
                $ticket_final->{$property} = $new;
                $ticket->{$property} = $new;
        }


        # walk back $ticket's state
        if (   ( !defined $new && !defined $ticket->{$property} )
            || ( defined $new && defined $ticket->{$property} && $ticket->{$property} eq $new ) )
        {
            $ticket->{$property} = $old;
        }

        $change->add_prop_change( name => $property, old => $old, new => $new );

    }

    $changeset->add_change( { change => $change } ) if $change->has_prop_changes;

    my $comment = Prophet::Change->new(
        {   record_type => 'comment',
            record_uuid => Data::UUID->new->create_str()
            ,    # comments are never edited, we can have a random uuid
            change_type => 'add_file'
        }
    );

    if ( my $content = $txn->content ) {
        if ( $content !~ /^\s*$/s ) {
            $comment->add_prop_change( name => 'created', new  => $txn->date->ymd . ' ' . $txn->date->hms);
            $comment->add_prop_change( name => 'creator', new  => $self->resolve_user_id_to( email_address => $txn->author ));
            $comment->add_prop_change( name => 'content',      new => $content );
            $comment->add_prop_change( name => 'content_type', new => 'text/html' );
            $comment->add_prop_change( name => 'ticket', new  => $ticket_uuid);

            $changeset->add_change( { change => $comment } );
        }
    }

    return undef unless $changeset->has_changes;
    return $changeset;
}

sub _recode_attachment_create {
    my $self   = shift;
    my %args   = validate( @_, { ticket => 1, txn => 1, changeset => 1, attachment => 1 } );
    my $change = Prophet::Change->new(
        {   record_type => 'attachment',
            record_uuid => $self->sync_source->uuid_for_url(
                $self->sync_source->remote_url . "/attachment/" . $args{'attachment'}->{'id'}
            ),
            change_type => 'add_file'
        }
    );
    $change->add_prop_change(
        name => 'content_type',
        old  => undef,
        new  => $args{'attachment'}->{'ContentType'}
    );
    $change->add_prop_change( name => 'created', old => undef, new => $args{'txn'}->{'Created'} );
    $change->add_prop_change(
        name => 'creator',
        old  => undef,
        new  => $self->resolve_user_id_to( email_address => $args{'attachment'}->{'Creator'} )
    );
    $change->add_prop_change(
        name => 'content',
        old  => undef,
        new  => $args{'attachment'}->{'Content'}
    );
    $change->add_prop_change(
        name => 'name',
        old  => undef,
        new  => $args{'attachment'}->{'Filename'}
    );
    $change->add_prop_change(
        name => 'ticket',
        old  => undef,
        new  => $self->sync_source->uuid_for_remote_id(
            $args{'ticket'}->{ $self->sync_source->uuid . '-id' }
        )
    );
    $args{'changeset'}->add_change( { change => $change } );
}

sub translate_status {
    my $self   = shift;
    my $status = shift;

    $status =~ s/^resolved$/closed/;
    return $status;
}

my %PROP_MAP;
sub translate_prop_names {
    my $self      = shift;
    my $changeset = shift;

    for my $change ( $changeset->changes ) {
        next unless $change->record_type eq 'ticket';

        my @new_props;
        for my $prop ( $change->prop_changes ) {
            next if ( ( $PROP_MAP{ lc( $prop->name ) } || '' ) eq '_delete' );
            $prop->name( $PROP_MAP{ lc( $prop->name ) } ) if $PROP_MAP{ lc( $prop->name ) };

            # Normalize away undef -> "" and vice-versa
            for (qw/new_value old_value/) {
                $prop->$_("") if !defined( $prop->$_() );
            }
            next if ( $prop->old_value eq $prop->new_value );

            if ( $prop->name =~ /^cf-(.*)$/ ) {
                $prop->name( 'custom-' . $1 );
            }

            push @new_props, $prop;

        }
        $change->prop_changes( \@new_props );

    }
    return $changeset;
}

sub resolve_user_id_to {
    my $self = shift;
    my $to   = shift;
    my $id   = shift;
    return $id . '@trac-instance.local';

}

__PACKAGE__->meta->make_immutable;
no Any::Moose;
1;
