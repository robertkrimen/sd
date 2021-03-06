#!/usr/bin/perl -w
use strict;

use Prophet::Test tests => 16;
use App::SD::Test;

BEGIN {
    require File::Temp;
    $ENV{'PROPHET_REPO'} = $ENV{'SD_REPO'} = File::Temp::tempdir( CLEANUP => 1 ) . '/_svb';
    diag 'export SD_REPO=' . $ENV{'PROPHET_REPO'} . "\n";
}
run_script( 'sd', [ 'init']);

my $replica_uuid = replica_uuid;

diag('changing settings to enable different behaviour with --verbose arg');
run_output_matches( 'sd', [ 'settings', '--set', '--', 'common_ticket_props',
    '["id","summary","status","milestone","owner","created","due","creator","reporter","original_replica"]' ],
    [
        'Trying to change common_ticket_props from ["id","summary","status","milestone","component","owner","created","due","creator","reporter","original_replica"] to ["id","summary","status","milestone","owner","created","due","creator","reporter","original_replica"].',
        ' -> Changed.',
    ]
);

# create ticket
my ($ticket_id, $ticket_uuid) = create_ticket_ok( '--summary', 'zomg!',
    '--owner', 'foo@bar.com');

# verify that it's correct
run_output_matches( 'sd', [ 'ticket', 'basics', '--batch', '--id', $ticket_id ],
    [
        "id: $ticket_id ($ticket_uuid)",
        'summary: zomg!',
        'status: new',
        'milestone: alpha',
        'owner: foo@bar.com',
        qr/^created: \d{4}-\d{2}-\d{2}.+$/,
        qr/^creator: /,
        'reporter: ' . $ENV{PROPHET_EMAIL},
        "original_replica: $replica_uuid",
    ]
);

App::SD::Test->set_editor("ticket-update-editor.pl --no-args $replica_uuid $ticket_uuid");

# update it
my ($comment_id, $comment_uuid) = App::SD::Test->update_ticket_with_editor_ok($ticket_id, $ticket_uuid);

# check output -- component prop should be hidden by common_ticket_props
run_output_matches( 'sd', [ 'ticket', 'basics', '--batch', '--id', $ticket_id ],
    [
        "id: $ticket_id ($ticket_uuid)",
        'summary: summary changed',
        'status: new',
        'milestone: alpha',
        qr/^created: \d{4}-\d{2}-\d{2}.+$/,
        'due: 2050-01-25 23:11:42',
        qr/^creator: /,
        'reporter: ' . $ENV{PROPHET_EMAIL},
        "original_replica: $replica_uuid",
    ]
);

sub check_comment_ok {
    # comment output verifies that the template presented to the user for
    # editing was correct
    run_output_matches( 'sd',
        [ 'ticket', 'comment', 'show', '--batch', '--id',  $comment_id ],
        [
            "id: $comment_id ($comment_uuid)",
            'content: template ok!',
            qr/^created: \d{4}-\d{2}-\d{2}.+$/,
            qr/^creator: /,
            "original_replica: $replica_uuid",
            qr/^ticket: $ticket_uuid$/,
        ]
    );
}

check_comment_ok();

# sd ticket edit 20 --all-props
App::SD::Test->set_editor("ticket-update-editor.pl --all-props $replica_uuid $ticket_uuid");

# update it
# template should show the hidden component prop
($comment_id, $comment_uuid) = App::SD::Test->update_ticket_with_editor_ok($ticket_id, $ticket_uuid, '--all-props');

# check output -- component prop should be hidden by common_ticket_props
run_output_matches( 'sd', [ 'ticket', 'basics', '--batch', '--id', $ticket_id  ],
    [
        "id: $ticket_id ($ticket_uuid)",
        'summary: now we are checking --all-props',
        'status: new',
        'milestone: alpha',
        "owner: $ENV{PROPHET_EMAIL}",
        qr/^created: \d{4}-\d{2}-\d{2}.+$/,
        qr/^creator: /,
        'reporter: ' . $ENV{PROPHET_EMAIL},
        "original_replica: $replica_uuid",
    ]
);

check_comment_ok();

# sd ticket edit 20 --verbose
App::SD::Test->set_editor("ticket-update-editor.pl --verbose $replica_uuid $ticket_uuid");

# update it
($comment_id, $comment_uuid) = App::SD::Test->update_ticket_with_editor_ok($ticket_id, $ticket_uuid, '--verbose');

# check output -- component prop should be hidden by common_ticket_props
run_output_matches( 'sd', [ 'ticket', 'basics', '--batch', '--id', $ticket_id ],
    [
        "id: $ticket_id ($ticket_uuid)",
        'summary: now we are checking --verbose',
        'status: new',
        'milestone: alpha',
        qr/^created: \d{4}-\d{2}-\d{2}.+$/,
        'due: 2050-01-31 19:14:09',
        qr/^creator: /,
        'reporter: ' . $ENV{PROPHET_EMAIL},
        "original_replica: $replica_uuid",
    ]
);

check_comment_ok();

# sd ticket edit 20 --verbose --all-props
App::SD::Test->set_editor("ticket-update-editor.pl --verbose-and-all $replica_uuid $ticket_uuid");

diag('changing settings for regression test: make sure props aren\'t deleted');
diag('if they weren\'t presented for editing in the first place');

run_output_matches( 'sd', [ 'settings', '--set', '--', 'common_ticket_props',
    '["id","summary","status","milestone","owner","created","due","creator","original_replica"]' ],
    [
        'Trying to change common_ticket_props from ["id","summary","status","milestone","owner","created","due","creator","reporter","original_replica"] to ["id","summary","status","milestone","owner","created","due","creator","original_replica"].',
        ' -> Changed.',
    ]
);

# update it
($comment_id, $comment_uuid) = App::SD::Test->update_ticket_with_editor_ok($ticket_id, $ticket_uuid, '--verbose', '--all-props');

# check output -- reporter prop should not have been deleted
# (need --verbose arg to check this)
run_output_matches( 'sd', [ 'ticket', 'basics', '--batch', '--id', $ticket_id, '--verbose' ],
    [
        "id: $ticket_id ($ticket_uuid)",
        'summary: now we are checking --verbose --all-props',
        'status: new',
        'milestone: alpha',
        "owner: $ENV{PROPHET_EMAIL}",
        qr/^created: \d{4}-\d{2}-\d{2}.+$/,
        qr/^creator: /,
        "original_replica: $replica_uuid",
        # no ordering is imposed on props not in common_ticket_props
        qr/(?:reporter: $ENV{PROPHET_EMAIL}|component: core)/,
        qr/(?:reporter: $ENV{PROPHET_EMAIL}|component: core)/,
    ]
);

check_comment_ok();
