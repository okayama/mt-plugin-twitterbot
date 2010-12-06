package MT::TwitterBot::Tweet;
use strict;

@MT::TwitterBot::Tweet::ISA = qw( MT::Object );
__PACKAGE__->install_properties( {
    column_defs => {
        'id' => 'integer not null auto_increment',
        'blog_id' => 'integer',
        'author_id' => 'integer',
        'name' => 'string(255)',
        'class' => 'string(25)',
        'day_of_week' => 'string(25)',
        'timezone' => 'string(25)',
        'is_special_day' => 'integer',
        'day_type' => 'integer',
        'date' => 'string(25)',
        'tweets' => 'text',
        'interval' => 'integer',
        'return_follow' => 'string(25)',
        'unfollow' => 'string(25)',
        'search_follow' => 'string(25)',
        'search_words' => 'text',
        'tweets_at_return_follow' => 'text',
        'tweets_at_search_follow' => 'text',
        'no_hash_tags_at_return_follow' => 'string(25)',
    },
    indexes => {
        'blog_id' => 1,
        'author_id' => 1,
        'name' => 1,
        'class' => 1,
        'day_of_week' => 1,
        'timezone' => 1,
        'is_special_day' => 1,
        'day_type' => 1,
        'date' => 1,
        'interval' => 1,
        'return_follow' => 1,
        'unfollow' =>  1,
        'search_follow' =>  1,
        'no_hash_tags_at_return_follow' =>  1,
    },
    datasource =>  'tweet',
    primary_key => 'id',
    audit => 1,
    child_of => 'MT::Blog',
} );

sub class_label {
    my $plugin = MT->component( 'TwitterBot' );
    return $plugin->translate( 'Tweet' );
}

sub class_label_plural {
    my $plugin = MT->component( 'TwitterBot' );
    return $plugin->translate( 'Tweet' );
}

sub blog {
    my ( $tweet ) = @_;
    $tweet->cache_property( 'blog', sub { my $blog_id = $tweet->blog_id;
                                          require MT::Blog;
                                          MT::Blog->load( $blog_id ) or
                                            $tweet->error( MT->translate( "Load of blog '[_1]' failed: [_2]", $blog_id, MT::Blog->errstr || MT->translate( "record does not exist." ) ) );
                                        }
                          );
}

1;
