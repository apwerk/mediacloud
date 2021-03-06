package MediaWords::Test::Solr;

=head1 NAME

MediaWords::Test::Supervisor - functions for using solr during testing

=head1 SYNOPSIS

    MediaWords::Test::Solr::set_test_index( $db )
=cut

use strict;
use warnings;

use Modern::Perl '2015';
use MediaWords::CommonLibs;

use Test::More;

use MediaWords::Solr;
use MediaWords::Solr::Dump;
use MediaWords::Test::DB::Environment;
use MediaWords::Util::Tags;

# remember that we already swapped the solr live collection
my $_swapped_live_collection;

require Exporter;
our @ISA    = qw(Exporter);
our @EXPORT = qw(test_story_query);

=head2 test_story_query( $db, $q, $expected_story, $label )

Run the given query against solr, adding an 'and stories_id:$expected_story->{ stories_id }' to make it return at
most one story.  Verify that the query succeeds and returns only the $expected_story.

=cut

sub test_story_query($$$;$)
{
    my ( $db, $q, $expected_story, $label ) = @_;

    $label //= 'test story query';

    my $expected_stories_id = $expected_story->{ stories_id };

    my $r = MediaWords::Solr::query( $db, { q => "$q and stories_id:$expected_stories_id", rows => 1_000_000 } );

    my $docs = $r->{ response }->{ docs };

    die( "no response.docs found in solr results: " . Dumper( $r ) ) unless ( $docs );

    my $got_stories_ids = [ map { $_->{ stories_id } } @{ $docs } ];

    is_deeply( $got_stories_ids, [ $expected_stories_id ], "$label: $q" );

}

# add story tags to stories for solr indexing
sub _add_story_tags_to_stories
{
    my ( $db, $stories ) = @_;

    my $tags     = [];
    my $num_tags = 5;

    for my $i ( 1 .. $num_tags )
    {
        push( @{ $tags }, MediaWords::Util::Tags::lookup_or_create_tag( $db, "test:test_$i" ) );
    }

    for my $story ( @{ $stories } )
    {
        my $tag = pop( @{ $tags } );
        unshift( @{ $tags }, $tag );
        $db->query( <<SQL, $story->{ stories_id }, $tag->{ tags_id } );
insert into stories_tags_map ( stories_id, tags_id ) values ( ?, ? )
SQL
    }
}

# add timespans to stories for solr indexing
sub _add_timespans_to_stories
{
    my ( $db, $stories ) = @_;

    my $topic = MediaWords::Test::DB::Create::create_test_topic( $db, "solr dump test" );

    my $snapshot = {
        topics_id     => $topic->{ topics_id },
        snapshot_date => '2018-01-01',
        start_date    => '2018-01-01',
        end_date      => '2018-01-01'
    };
    $snapshot = $db->create( 'snapshots', $snapshot );

    my $timespans = [];
    for my $i ( 1 .. 5 )
    {
        my $timespan = {
            snapshots_id      => $snapshot->{ snapshots_id },
            start_date        => '2018-01-01',
            end_date          => '2018-01-01',
            story_count       => 1,
            story_link_count  => 1,
            medium_count      => 1,
            medium_link_count => 1,
            tweet_count       => 1,
            period            => 'overall'

        };
        push( @{ $timespans }, $db->create( 'timespans', $timespan ) );
    }

    for my $story ( @{ $stories } )
    {
        my $timespan = pop( @{ $timespans } );
        unshift( @{ $timespans }, $timespan );

        $db->query( <<SQL, $story->{ stories_id }, $timespan->{ timespans_id } );
insert into snap.story_link_counts ( timespans_id, stories_id, media_inlink_count, inlink_count, outlink_count )
    values ( \$2, \$1, 1, 1, 1 );
SQL
    }

}

=head2 create_indexed_test_story_stack( $db, $data )

Create a test story stack, add content to the stories, and index them.  The stories will have associated timespans_id,
stories_tags_map, and processed_stories entries added as well.  Returns the test story stack as returned by
MediaWords::Test::DB::Create::create_test_story_stack()

=cut

sub create_indexed_test_story_stack($$)
{
    my ( $db, $data ) = @_;

    my $media = MediaWords::Test::DB::Create::create_test_story_stack( $db, $data );

    $media = MediaWords::Test::DB::Create::add_content_to_test_story_stack( $db, $media );

    my $test_stories = $db->query( "select * from stories order by md5( stories_id::text )" )->hashes;

    # add ancilliary data so that it can be queried in solr
    _add_story_tags_to_stories( $db, $test_stories );
    _add_timespans_to_stories( $db, $test_stories );

    MediaWords::Test::Solr::setup_test_index( $db );

    return $media;
}

=head2 setup_test_index( $db )

Switch the active sole index to the staging collection.  Delete everything currently in that collection.  Run a
full solr import based on the current postgres db.

Using this function leaves the side effect of leaving all of the test data sitting in the staging collection after
it has been run.

Due to a failsafe built into MediaWords::Solr::Dump::generate_and_import_data, the delete of the staging collection
data will fail if there are more than 100 million sentences in the index (to prevent accidental deletion of
production data).

The function assumes that whichever solr collection is live when it is first called is the live collection.  It will
use the other collection no matter how many times it is called.

=cut

sub setup_test_index($)
{
    my ( $db ) = @_;

    if ( !MediaWords::Test::DB::Environment::using_test_database() )
    {
        LOGDIE( 'setup_test_index can only be called while connected to postgres test database' );
    }

    if ( !$_swapped_live_collection )
    {
        MediaWords::Solr::swap_live_collection( $db );
        $_swapped_live_collection = 1;
    }

    MediaWords::Solr::Dump::delete_all_stories( $db );
    MediaWords::Solr::Dump::queue_all_stories( $db );
    MediaWords::Solr::Dump::import_data( $db, { full => 1, throttle => 0 } );
}

=head2 using_test_index()

Return true if setup_test_index() has been called to run on the staging index.

=cut

sub using_test_index()
{
    return $_swapped_live_collection;
}

1;
