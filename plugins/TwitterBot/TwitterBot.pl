package MT::Plugin::TwitterBot;
use strict;
use MT;
use MT::Plugin;
use base qw( MT::Plugin );

use Calendar::Japanese::Holiday;
use Encode;
use HTTP::Request::Common;
use LWP::UserAgent;
use Digest::SHA1;
use Net::OAuth;
use XML::Simple;
$Net::OAuth::PROTOCOL_VERSION = Net::OAuth::PROTOCOL_VERSION_1_0A; 

use MT::Util qw( encode_url offset_time_list format_ts wday_from_ts );

our $PLUGIN_NAME = 'TwitterBot';
our $PLUGIN_VERSION = '1.0';
our $PLUGIN_SCHEMA_VERSION = '0.367';

my $plugin = new MT::Plugin::TwitterBot( {
    id => $PLUGIN_NAME,
    key => lc $PLUGIN_NAME,
    name => $PLUGIN_NAME,
    version => $PLUGIN_VERSION,
    schema_version => $PLUGIN_SCHEMA_VERSION,
    description => '<MT_TRANS phrase=\'Available TwitterBot.\'>',
    author_name => 'okayama',
    author_link => 'http://weeeblog.net/',
    blog_config_template => 'twitterbot_config.tmpl',
    settings => new MT::PluginSettings( [
        [ 'consumer_key' ],
        [ 'consumer_secret' ],
        [ 'callback_url' ],
        [ 'access_token' ],
        [ 'access_secret' ],
        [ 'bitly_username' ],
        [ 'bitly_api_key' ],
        [ 'hashtag' ],
        [ 'tweets_interval', { Default => 60 } ],
        [ 'since_id_for_search', { Default => undef } ],
        [ 'japan_only_for_follow', { Default => 1 } ],
        [ 'unfollow_interval', { Default => 86400 } ],
        [ 'unfollow_last_time', { Default => undef } ],
        [ 'follow_return_follow_follower_ratio', { Default => 50 } ],
        [ 'default_search_words' ],
        [ 'default_tweets_at_search_follow' ],
        [ 'default_tweets_at_return_follow' ],
    ] ),
    l10n_class => 'MT::TwitterBot::L10N',
} );
MT->add_plugin( $plugin );

sub init_registry {
    my $plugin = shift;
    $plugin->registry( {
        object_types => {
            'tweet' => 'MT::TwitterBot::Tweet',
        },
        applications => {
            cms => {
                menus => {
                    'twitterbot' => {
                        label => 'Tweet',
                        order => 10000,
                    },
                    'twitterbot:list_tweet' => {
                        label => 'Manage',
                        mode => 'list_tweet',
                        permission => "administer_blog",
                        system_permission => "manage_plugins",
                        order => 100,
                        view => [ 'website', 'blog' ],
                    },
                    'twitterbot:create_tweet' => {
                        label => 'New',
                        mode => 'view',
                        args => { _type => 'tweet' },
                        order => 200,
                        permission => "administer_blog",
                        system_permission => "manage_plugins",
                        view => [ 'website', 'blog' ],
                    },
                },
                methods => {
                    twitter_oauth_callback => \&_mode_twitter_oauth_callback,
                    twitter_oauth_request => \&_mode_twitter_oauth_request,
                    twitter_oauth_test => \&_mode_twitter_oauth_test,
                    list_tweet => \&_mode_list_tweet,
                },
            },
        },
        callbacks => {
            'MT::App::CMS::pre_run' => \&_cb_pre_run,
            'MT::App::CMS::template_source.twitterbot_config' => \&_cb_tp_twitterbot_config,
            'MT::App::CMS::template_param.edit_tweet' => \&_cb_tp_edit_tweet,
            'app_pre_listing_list_tweet' => \&_cb_app_pre_listing_list_tweet,
        },
        tasks => {
            twitterbot => {
                label    => 'TwitterBot Task',
                frequency => 5,
                code      => \&_task_twitter_bot,
            },
        },
   } );
}

sub _cb_app_pre_listing_list_tweet {
    my ( $cb, $app, $terms, $args, $param, $hasher ) = @_;
    my $filter = $app->param( 'filter' );
    my $filter_val = $app->param( 'filter_val' );
    if ( defined $filter_val ) {
        if ( $filter_val eq '0' ) {
            $$terms{ $filter } = $filter_val;
            $$param{ 'filter' } = $filter;
            $$param{ 'filter_val' } = $filter_val;
        }
    }
}

sub _task_twitter_bot {
    my @blogs = MT->model( 'blog' )->load( { class => '*' } );
    for my $blog ( @blogs ) {
        my $blog_id = $blog->id;
        my $tweets = _select_tweets( $blog );
        if ( my $tweet = _choice_at_random( $tweets ) ) {
            if ( my $text = $tweet->tweets ) {
#                 my @tweet_list = split( "\n", $text );
#                 my $tweet = _choice_at_random( \@tweet_list );
#                 if ( my $res = _update_twitter( $blog_id, $tweet ) ) {
                my %args = (
                    tweets => $text,
                );
                if ( my $res = _tweets_from_tmpl_list( $blog_id, \%args ) ) {
                    my $log_message = $plugin->translate( 'Update twitter success: [_1]', $res );
                    _save_success_log( $log_message, $blog_id );
                }
            }
            if ( my $unfollow = $tweet->unfollow ) {
                _unfollow( $blog_id );
            }
            if ( my $return_follow = $tweet->return_follow ) {
                my $args = { tweets => $tweet->tweets_at_return_follow,
                             no_hash_tags => $tweet->no_hash_tags_at_return_follow,
                           };
                _follow_return( $blog_id, $args );
            }
            if ( my $search_follow = $tweet->search_follow ) {
                if ( my $search_words = $tweet->search_words ) {
                    my @search_words = split( "\n", $search_words );
                    my $args = { tweets => $tweet->tweets_at_search_follow };
                    _search_follow( $blog_id, \@search_words, $args );
                }
            }
        }
    }
}

sub _search_follow {
    my ( $blog_id, $keywords, $args ) = @_;
    my $scope = 'blog:' . $blog_id;
    my $since_id = $plugin->get_config_value( 'since_id_for_search', $scope );
    my $jp_only = $plugin->get_config_value( 'japan_only_for_follow', $scope );
    for my $keyword ( @$keywords ) {
        if ( my $res = _search_by_words( $blog_id, $keyword, $since_id, $jp_only ) ) {
            if ( $res->{ id } ) {
                my $screen_name = $res->{ author }->{ uri };
                $screen_name =~ s!^.*/!!;
                $since_id = $res->{ id };
                $since_id =~ s!^.*\:!!;
                if ( $screen_name = _create_friends( $blog_id, $screen_name ) ) {
                    my $params = { screen_name => $screen_name,
                                   tweet => $res->{ title },
                                 };
                    _tweets_from_tmpl_list( $blog_id, $args, $params );
                    my $log = $plugin->translate( 'Follow success: [_1]', $screen_name );
                    _save_success_log( $log, $blog_id );
                }
            } else {
                for my $key ( keys %$res ) {
                    my $screen_name = $res->{ $key }->{ author }->{ uri };
                    $screen_name =~ s!^.*/!!;
                    $since_id = $key;
                    $since_id =~ s!^.*\:!!;
                    if ( $screen_name = _create_friends( $blog_id, $screen_name ) ) {
                        my $params = { screen_name => $screen_name,
                                       tweet => $res->{ $key }->{ title },
                                     };
                        _tweets_from_tmpl_list( $blog_id, $args, $params );
                        my $log = $plugin->translate( 'Follow success: [_1]', $screen_name );
                        _save_success_log( $log, $blog_id );
                    }
                }
            }
            $plugin->set_config_value( 'since_id_for_search', $since_id, $scope );
        }
    }
}

sub _tweets_from_tmpl_list {
    my ( $blog_id, $args, $params ) = @_;
    if ( my $tmpl_list = $args->{ tweets } ) {
        if ( my @templates = split( "\n", $tmpl_list ) ) {
            if ( my $tmpl = _choice_at_random( \@templates ) ) {
                my $no_hash_tags = $args->{ no_hash_tags };
                my $options = { no_hash_tags => $no_hash_tags };
                return _tweet_from_tmpl( $blog_id, $tmpl, $params, $options );
            }
        }
    }
}

sub _tweet_from_tmpl {
    my ( $blog_id, $tmpl, $params, $options ) = @_;
    return unless $blog_id;
    return unless $tmpl;
    if ( my $update_tweet = _build_tmpl( $tmpl, $params, $blog_id ) ) {
        _update_twitter( $blog_id, $update_tweet, $options );
        return $update_tweet;
    }
    return 0;
}

sub _search_by_words {
    my ( $blog_id, $keywords, $since_id, $jp_only ) = @_;
    if ( $keywords ) {
        my $request_url = 'http://search.twitter.com/search.atom';
        my $request_method = 'GET';
        $keywords = $keywords . ' -rt -via';
        my $param = { 'q' => $keywords,
                      ( $since_id ? ( since_id => $since_id ) : () ),
                      ( $jp_only ? ( lang => 'ja' ) : () ),
                    };
        if ( my $response = _oauth_request( $blog_id, $request_url, $request_method, $param ) ) {
            unless ( $response->is_success ) {
                my $log = $plugin->translate( 'Error get friends ids: [_1]', $response->status_line );
                _save_error_log( $log, $blog_id );
                return 0;
            }
            if ( my $xml = $response->content ) {
                my $data = XMLin( $xml );
                return $data->{ entry };
            }
        }
    }
    return 0;
}

sub _unfollow {
    my ( $blog_id ) = @_;
    my $scope = 'blog:' . $blog_id;
    my $unfollow_last_time = $plugin->get_config_value( 'unfollow_last_time', $scope );
    unless ( $unfollow_last_time ) {
        $unfollow_last_time = time;
        $plugin->set_config_value( 'unfollow_last_time', $unfollow_last_time, $scope );
    }
    my $unfollow_interval = $plugin->get_config_value( 'unfollow_interval', $scope ) || 0;
    if ( ( time - $unfollow_last_time ) > $unfollow_interval ) {
        my $followers_ids = _get_followers_ids( $blog_id );
        push( my @followers, ( ref $followers_ids eq 'ARRAY' ? @$followers_ids : $followers_ids ) );
        my $friends_ids = _get_friends_ids( $blog_id );
        push( my @friends, ( ref $friends_ids eq 'ARRAY' ? @$friends_ids : $friends_ids ) );
        for my $friend_id ( @friends ) {
            unless ( grep { $_ eq $friend_id } @followers ) {
                if ( my $screen_name = _destroy_friends( $blog_id, $friend_id ) ) {
                    my $log = $plugin->translate( 'Unfollow success: [_1]', $screen_name );
                    _save_success_log( $log, $blog_id );
                }
            }
        }
        $plugin->set_config_value( 'unfollow_last_time', time, $scope );
    }
        
}

sub _follow_return {
    my ( $blog_id, $args ) = @_;
    my $followers_ids = _get_followers_ids( $blog_id );
    push( my @followers, ( ref $followers_ids eq 'ARRAY' ? @$followers_ids : $followers_ids ) );
    my $friends_ids = _get_friends_ids( $blog_id );
    push( my @friends, ( ref $friends_ids eq 'ARRAY' ? @$friends_ids : $friends_ids ) );
    for my $follower_id ( @followers ) {
        unless ( grep { $_ eq $follower_id } @friends ) {
            if ( _follow_filter( $blog_id, $follower_id ) ) {
                if ( my $screen_name = _create_friends( $blog_id, $follower_id ) ) {
                    my $params = { screen_name => $screen_name };
                    _tweets_from_tmpl_list( $blog_id, $args, $params );
                    my $log = $plugin->translate( 'Follow success: [_1]', $screen_name );
                    _save_success_log( $log, $blog_id );
                }
            }
        }
    }
}

sub _follow_filter {
    my ( $blog_id, $screen_name ) = @_;
    my $scope = 'blog:' . $blog_id;
    my $follow_return_follow_follower_ratio = $plugin->get_config_value( 'follow_return_follow_follower_ratio', $scope ) || 0;
    if ( $follow_return_follow_follower_ratio ) {
        if ( my $user = _get_user_info( $blog_id, $screen_name ) ) {
            return 0 unless $user->{ followers_count };
            return 0 if int( $user->{ friends_count } / $user->{ followers_count } ) > $follow_return_follow_follower_ratio;
            return 1;
        }
    }
}

sub _get_user_info {
    my ( $blog_id, $screen_name ) = @_;
    my $request_url = 'http://api.twitter.com/1/users/show/' . $screen_name . '.xml';
    my $request_method = 'GET';
    if ( my $response = _oauth_request( $blog_id, $request_url, $request_method ) ) {
        unless ( $response->is_success ) {
            my $log = $plugin->translate( 'Error get user info: [_1]', $response->status_line );
            _save_error_log( $log, $blog_id );
            return 0;
        }
        if ( my $xml = $response->content ) {
            my $data = XMLin( $xml );
            return $data;
        }
    }
    return 0;

}

sub _cb_tp_edit_tweet {
    my ( $cb, $app, $param, $tmpl ) = @_;
    if ( my $blog = $app->blog ) {
        my @tl = offset_time_list( time, $blog );
        my $ts = sprintf "%04d-%02d-%02d", $tl[ 5 ]+1900, $tl[ 4 ]+1, $tl[ 3 ];
        $param->{ default_date } = $ts;
        unless ( $app->param( 'id' ) ) {
            my $scope = 'blog:' . $blog->id;
            if ( my $default_search_words = $plugin->get_config_value( 'default_search_words', $scope ) ) {
                $param->{ search_words } = $default_search_words;
            }
            if ( my $default_tweets_at_search_follow = $plugin->get_config_value( 'default_tweets_at_search_follow', $scope ) ) {
                $param->{ tweets_at_search_follow } = $default_tweets_at_search_follow;
            }
            if ( my $default_tweets_at_return_follow = $plugin->get_config_value( 'default_tweets_at_return_follow', $scope ) ) {
                $param->{ tweets_at_return_follow } = $default_tweets_at_return_follow;
            }
        }
    }
}

sub _select_tweets {
    my ( $blog ) = @_;
    my @tl = offset_time_list( time, $blog );
    my $formatted_date = sprintf "%04d-%02d-%02d", $tl[ 5 ]+1900, $tl[ 4 ]+1, $tl[ 3 ];
    my $wday = wday_from_ts( $tl[ 5 ] + 1900, $tl[ 4 ] + 1, $tl[ 3 ] );
    my $is_holiday = isHoliday( $tl[ 5 ] + 1900, $tl[ 4 ] + 1, $tl[ 3 ], 1 );
    unless ( $is_holiday ) {
        if ( $wday eq '0' or $wday eq '6' ) {
            $is_holiday = 1;
        }
    }
    my $hour = $tl[ 2 ];
    if ( $blog ) {
        my $blog_id = $blog->id;
        my @tweets = MT->model( 'tweet' )->load( { blog_id => $blog_id,
                                                   is_special_day => 1,
                                                   date => $formatted_date,
                                                   timezone => $hour,
                                                   day_type => ( $is_holiday ? [ 1, 3 ] : [ 1, 2 ] ),
                                                 },
                                               );
        unless ( @tweets ) {
            @tweets = MT->model( 'tweet' )->load( { blog_id => $blog_id,
                                                    is_special_day => 1,
                                                    date => $formatted_date,
                                                    timezone => 'DEFAULT',
                                                    day_type => ( $is_holiday ? [ 1, 3 ] : [ 1, 2 ] ),
                                                  },
                                                );
        }
        unless ( @tweets ) {
            @tweets = MT->model( 'tweet' )->load( { blog_id => $blog_id,
                                                    is_special_day => 0,
                                                    day_of_week => $wday,
                                                    timezone => $hour,
                                                    day_type => ( $is_holiday ? [ 1, 3 ] : [ 1, 2 ] ),
                                                  },
                                                );
        }
        unless ( @tweets ) {
            @tweets = MT->model( 'tweet' )->load( { blog_id => $blog_id,
                                                    is_special_day => 0,
                                                    day_of_week => $wday,
                                                    timezone => 'DEFAULT',
                                                    day_type => ( $is_holiday ? [ 1, 3 ] : [ 1, 2 ] ),
                                                  },
                                                );
        }
        unless ( @tweets ) {
            @tweets = MT->model( 'tweet' )->load( { blog_id => $blog_id,
                                                    is_special_day => 0,
                                                    day_of_week => 'DEFAULT',
                                                    timezone => $hour,
                                                    day_type => ( $is_holiday ? [ 1, 3 ] : [ 1, 2 ] ),
                                                  },
                                                );
        }
        unless ( @tweets ) {
            @tweets = MT->model( 'tweet' )->load( { blog_id => $blog_id,
                                                    is_special_day => 0,
                                                    day_of_week => 'DEFAULT',
                                                    timezone => 'DEFAULT',
                                                    day_type => ( $is_holiday ? [ 1, 3 ] : [ 1, 2 ] ),
                                                  },
                                                );
        }
        return \@tweets;
    }
}

sub _choice_at_random {
    my ( $items ) = @_;
    if ( $items ) {
        return splice @$items, int rand @$items, 1;
    }
}

sub _update_twitter {
    my ( $blog_id, $message, $options ) = @_;
    my $scope = 'blog:' . $blog_id;
    my $consumer_key = $plugin->get_config_value( 'consumer_key', $scope );
    my $consumer_secret = $plugin->get_config_value( 'consumer_secret', $scope );
    my $access_token = $plugin->get_config_value( 'access_token', $scope );
    my $access_secret = $plugin->get_config_value( 'access_secret', $scope );
    my $bitly_username = $plugin->get_config_value( 'bitly_username', $scope );
    my $bitly_api_key = $plugin->get_config_value( 'bitly_api_key', $scope );

    my $url = $options->{ url };
    my $no_hash_tags = $options->{ no_hash_tags };
    my $max_tweet_length = 140;
    my $cut_str_length = 3;
    my $cut_str = '...';
    my $etc_length = 1;
    my $hashtag;

    if ( $no_hash_tags ) {
        $etc_length = 0;
    } else {
        $hashtag = $plugin->get_config_value( 'hashtag', $scope );
        if ( ! $no_hash_tags && $hashtag ) {
            my @each_tags = split( ',', $hashtag );
            @each_tags = map { $_ =~ s/\s//g; $_; } @each_tags;
            $hashtag = '#' . join( ' #', @each_tags );
        }
    }
    my $hashtag_length = $hashtag ? MT::I18N::length_text( $hashtag ) : 0;

    if ( $message ) {
        if ( MT->config->DebugModeForTwitterBot ) {
            $message .= ' ' . _get_datetime( $blog_id );
        }
        $message .= ( $url ? ' ' . $url : '' );
        $message = _shorten_url( $message, $bitly_username, $bitly_api_key );
        $message = MT::I18N::encode_text( $message, undef, 'utf-8' );
    }
    my $message_length = $message ? MT::I18N::length_text( $message ) : 0;
    
    my $tweet_length = $message_length + $hashtag_length + $etc_length;
    my $subtraction_length = $hashtag_length + $etc_length + $cut_str_length;

    if ( $tweet_length > $max_tweet_length ) {
        $message_length = ( $max_tweet_length - $subtraction_length );
        $message = MT::I18N::substr_text( $message, 0, $message_length ) . $cut_str;
    }
    
    my $tweet = $message . ( $hashtag ? ' ' . $hashtag : '' );
    $tweet = MT::I18N::decode_utf8( $tweet );
    
    my $api_request_url  = 'https://twitter.com/statuses/update.xml';
    my $request_method = 'POST'; 
    
    my $request  = Net::OAuth->request( "protected resource" )->new(
        consumer_key    => $consumer_key,
        consumer_secret => $consumer_secret,
        request_url => $api_request_url,
        request_method => $request_method,
        signature_method => 'HMAC-SHA1',
        timestamp => time,
        nonce => Digest::SHA1::sha1_base64( time . $$ . rand ),
        token => $access_token,
        token_secret => $access_secret,
        extra_params => { status => $tweet },
    );
    $request->sign;

    my $ua = LWP::UserAgent->new;
    my $http_header = HTTP::Headers->new( 'User-Agent' => $PLUGIN_NAME );
    my $http_request = HTTP::Request->new( $request_method, $api_request_url, $http_header, $request->to_post_body );
    my $res = $ua->request( $http_request );
    unless ( $res->is_success ) {
        my $log = $plugin->translate( 'Error update twitter: [_1]', $res->status_line );
        _save_error_log( $log, $blog_id );
        return 0;
    }
    return $tweet;
}

sub _get_oauth_params {
    my ( $blog_id ) = @_;
    my $scope = 'blog:' . $blog_id;
    my %settings = (
        consumer_key => $plugin->get_config_value( 'consumer_key', $scope ),
        consumer_secret => $plugin->get_config_value( 'consumer_secret', $scope ),
        access_token => $plugin->get_config_value( 'access_token', $scope ),
        access_secret => $plugin->get_config_value( 'access_secret', $scope ),
    );
    return \%settings;
}

sub _oauth_request {
    my ( $blog_id, $request_url, $request_method, $extra_params ) = @_;
    if ( $blog_id && $request_url && $request_method ) {
        my $oauth_params = _get_oauth_params( $blog_id );
        my $consumer_key = $oauth_params->{ 'consumer_key' };
        my $consumer_secret = $oauth_params->{ 'consumer_secret' };
        my $access_token = $oauth_params->{ 'access_token' };
        my $access_secret = $oauth_params->{ 'access_secret' };
        my $request = Net::OAuth->request( 'protected resource' )->new(
           consumer_key => $consumer_key,
           consumer_secret => $consumer_secret,
           request_url => $request_url,
           request_method => $request_method,
           signature_method => 'HMAC-SHA1',
           timestamp => time,
           nonce => Digest::SHA1::sha1_base64( time . $$ . rand ),
           token => $access_token,
           token_secret => $access_secret,
           ( $extra_params ? ( extra_params => $extra_params ) : () ),
        );
        $request->sign;
        my $ua = LWP::UserAgent->new;
        if ( my $response = ( $request_method =~ /^get$/i ? $ua->get( $request->to_url ) : $ua->post( $request->to_url ) ) ) {
            return $response;
        }
    }
    return 0;
}

sub _get_friends_ids {
    my ( $blog_id ) = @_;
    my $request_url = 'http://twitter.com/friends/ids.xml';
    my $request_method = 'GET';
    if ( my $response = _oauth_request( $blog_id, $request_url, $request_method ) ) {
        unless ( $response->is_success ) {
            my $log = $plugin->translate( 'Error get friends ids: [_1]', $response->status_line );
            _save_error_log( $log, $blog_id );
            return 0;
        }
        if ( my $xml = $response->content ) {
            my $data = XMLin( $xml );
            if ( my $ids = $data->{ id } ) {
                return $ids;
            }
        }
    }
    return 0;
}

sub _get_followers_ids {
    my ( $blog_id ) = @_;
    my $request_url = 'http://twitter.com/followers/ids.xml';
    my $request_method = 'GET';
    if ( my $response = _oauth_request( $blog_id, $request_url, $request_method ) ) {
        unless ( $response->is_success ) {
            my $log = $plugin->translate( 'Error get followers ids: [_1]', $response->status_line );
            _save_error_log( $log, $blog_id );
            return 0;
        }
        if ( my $xml = $response->content ) {
            my $data = XMLin( $xml );
            if ( my $ids = $data->{ id } ) {
                return $ids;
            }
        }
    }
    return 0;
}

sub _destroy_friends {
    my ( $blog_id, $friend_id ) = @_;
    my $request_url = 'http://api.twitter.com/1/friendships/destroy/' . $friend_id . '.xml';
    my $request_method = 'POST';
    if ( my $response = _oauth_request( $blog_id, $request_url, $request_method ) ) {
        unless ( $response->is_success ) {
            my $log = $plugin->translate( 'Error destroy friends to [_2]: [_1]', $response->status_line, $friend_id );
            _save_error_log( $log, $blog_id );
            return 0;
        }
        if ( my $xml = $response->content ) {
            my $data = XMLin( $xml );
            return $data->{ screen_name };
        }
    }
    return 0;
}

sub _create_friends {
    my ( $blog_id, $friend_id ) = @_; 
    unless ( _is_friends( $blog_id, $friend_id ) ) {
        my $request_url = 'http://api.twitter.com/1/friendships/create/' . $friend_id . '.xml';
        my $request_method = 'POST';
        if ( my $response = _oauth_request( $blog_id, $request_url, $request_method ) ) {
            unless ( $response->is_success ) {
                my $log = $plugin->translate( 'Error create friends to [_2]: [_1]', $response->status_line, $friend_id );
                _save_error_log( $log, $blog_id );
                return 0;
            }
            if ( my $xml = $response->content ) {
                my $data = XMLin( $xml );
                return $data->{ screen_name };
            }
        }
    }
    return 0;
}

sub _is_friends {
    my ( $blog_id, $target_screen_name ) = @_; 
    my $request_url = 'http://api.twitter.com/1/friendships/show.xml';
    my $request_method = 'GET';
    my $param = { target_screen_name => $target_screen_name };
    if ( my $response = _oauth_request( $blog_id, $request_url, $request_method, $param ) ) {
        unless ( $response->is_success ) {
            my $log = $plugin->translate( 'Error get followers ids: [_1]', $response->status_line );
            _save_error_log( $log, $blog_id );
            return 0;
        }
        if ( my $xml = $response->content ) {
            my $data = XMLin( $xml );
            if ( my $following = $data->{ source }->{ following }->{ content } ) {
                if ( $following eq 'true' ) {
                    return 1;
                }
            }
        }
    }
    return 0;
}

sub _cb_pre_run {
    my ( $eh, $app ) = @_;
    if ( ( $app->mode eq 'view' ) && ( $app->param( '_type' ) eq 'tweet' ) ) {
        $app->{ plugin_template_path } = File::Spec->catdir( $plugin->path, 'tmpl', $app->id );
    }
}

sub _mode_list_tweet {
    my $app = shift;
    my $blog_id = $app->param( 'blog_id' );
    unless ( $app->user->permissions( $blog_id ) ) {
        $app->error( 'Permission denied.' );
    }
    my $state_editable = 1;
    my $code = sub {
        my ( $obj, $row ) = @_;
        my $blog = $obj->blog;
        if ( my $created_ts = $obj->created_on ) {
            $row->{ created_on_formatted } =
                format_ts( undef, $created_ts, ( $blog || undef ), $app->user ? $app->user->preferred_language : undef );
        }
        if ( my $modified_ts = $obj->modified_on ) {
            $row->{ modified_on_formatted } =
                format_ts( undef, $modified_ts, ( $blog || undef ), $app->user ? $app->user->preferred_language : undef );
        }
        $row->{ has_edit_access } = 1;
    };
    my %terms;
    my %param;
    if ( $app->param( 'saved_deleted' ) ) {
        $param{ saved_deleted } = $state_editable;
    }
    if ( my $filter = $app->param( 'filter' ) ) {
        if ( $filter eq 'day_of_week' ) {
            $param{ filter_label } = $plugin->translate( 'Day of week' );
        } elsif ( $filter eq 'timezone' ) {
            $param{ filter_label } = $plugin->translate( 'Timezone' );
        }
    }
    $param{ status_changed } = $app->param( 'status_changed' );
    $param{ object_type } = 'tweet';
    $param{ screen_id } = 'list-tweet';
    $param{ screen_class } = 'list-tweet';
    $param{ 'LIST_NONCRON' } = 1;
    $param{ search_label } = $plugin->translate( 'Tweet' );
    $param{ state_editable } = $state_editable;
    $app->{ 'plugin_template_path' } = File::Spec->catdir( $plugin->path, 'tmpl', $app->id );
#     my @sort;
#     push @sort, { column => 'day_of_week',
#                   desc => 'ascend',
#                 };
#     push @sort, { column => 'timezone',
#                   desc => 'descend',
#                 };
    return $app->listing(
        {
            type => 'tweet',
            code => $code,
            args => { sort => 'modified_on', direction => 'descend' },
            params => \%param,
            terms => \%terms,
        }
    );
}

sub _mode_twitter_oauth_test {
    my $app = shift;
    my %param;
    if ( my $blog_id = $app->param( 'blog_id' ) ) {
        my $scope = 'blog:' . $blog_id;
        my $consumer_key = $plugin->get_config_value( 'consumer_key', $scope );
        my $consumer_secret = $plugin->get_config_value( 'consumer_secret', $scope );
        my $access_token = $plugin->get_config_value( 'access_token', $scope );
        my $access_secret = $plugin->get_config_value( 'access_secret', $scope );
        my $blog = MT->model( 'blog' )->load( { id => $blog_id } );
        my @tl = offset_time_list( time, $blog );
        my $ts = sprintf "%04d%02d%02d%02d%02d%02d", $tl[ 5 ] + 1900, $tl[ 4 ] + 1, @tl[ 3, 2, 1, 0 ];
        use MT::Template::Context;
        my $ctx = MT::Template::Context->new;
        my $datetime = $ctx->build_date( { ts => $ts,
                                           'format' => "%Y-%m-%dT%H:%M:%S",
                                         }
                                       );
        my $message = $plugin->translate( 'This post is test for TwitterBot' ) . ': ' . $datetime;
        if ( _update_twitter( $blog_id, $message ) ) {
            $param{ 'page_title' } = $plugin->translate( 'Test post success!' );
#             $param{ 'msg' } = $plugin->translate( 'Please check your twitter.' );
            my $uri_cfg_plugins = $app->base . $app->uri( mode => 'cfg_plugins', args => { blog_id => $blog_id } );
            $param{ 'msg' } = $plugin->translate( 'Please check your twitter. <a href="[_1]">The setting is completed a little more.</a>.', $uri_cfg_plugins );
            $param{ 'is_success' } = 1;
        }
    }
    unless ( $param{ 'is_success' } ) {
        $param{ 'page_title' } = $plugin->translate( 'Test post failed!' );
        $param{ 'msg' } = $plugin->translate( 'Test post failed. Please check your settings.' );
    }
    $app->{ plugin_template_path } = File::Spec->catdir( $plugin->path,'tmpl' );
    my $tmpl = 'twitterbot_authorized.tmpl';
    return $app->build_page( $tmpl, \%param );
}

sub _mode_twitter_oauth_request {
    my $app = shift;
    if ( my $blog_id = $app->param( 'blog_id' ) ) {
        my $scope = 'blog:' . $blog_id;
        my $consumer_key = $plugin->get_config_value( 'consumer_key', $scope );
        my $consumer_secret = $plugin->get_config_value( 'consumer_secret', $scope );
        my $callback_url = $plugin->get_config_value( 'callback_url', $scope );
        
        my $request_token_url = 'http://twitter.com/oauth/request_token';
        my $request_method = 'GET';
        my $request = Net::OAuth->request( "request token" )->new(
            consumer_key => $consumer_key,
            consumer_secret => $consumer_secret,
            request_url => $request_token_url,
            request_method => $request_method,
            signature_method => 'HMAC-SHA1',
            timestamp => time,
            nonce => Digest::SHA1::sha1_base64( time . $$ . rand ),
            callback => $callback_url,
        );    
        $request->sign;
    
        my $ua = LWP::UserAgent->new;
        my $http_header = HTTP::Headers->new( 'Authorization' => $request->to_authorization_header );
        my $http_request = HTTP::Request->new( $request_method, $request_token_url, $http_header );
        my $res = $ua->request( $http_request );
        if ( $res->is_success ) {
            my $response = Net::OAuth->response( 'request token' )->from_post_body( $res->content );
            my $request_token = $response->token;
            my $request_token_secret = $response->token_secret;
            my $authorize_url = 'http://twitter.com/oauth/authorize?oauth_token=' . $request_token;
            my $cookie = $app->bake_cookie( -name=>'twitterbot',
                                            -value => { blog_id => $blog_id,
                                                        token => $request_token,
                                                        token_secret => $request_token_secret,
                                                      },
                                            -path => '/',
                                          );
            return $app->redirect( $authorize_url, UseMeta => 1, -cookie => $cookie );
        }
    }
    my %param;
    $param{ 'page_title' } = $plugin->translate( 'OAuth failed!' );
    $param{ 'msg' } = $plugin->translate( 'OAuth failed. Please check your settings' );
    $app->{ plugin_template_path } = File::Spec->catdir( $plugin->path,'tmpl' );
    my $tmpl = 'twitterbot_authorized.tmpl';
    return $app->build_page( $tmpl, \%param );
}

sub _mode_twitter_oauth_callback {
    my $app = shift;
    my $cookies = $app->cookies();
    my %param;
    if ( my %cookies = $cookies->{ 'twitterbot' }->value ) {
        my $blog_id = $cookies{ 'blog_id' };
        my $request_token = $cookies{ 'token' };
        my $request_token_secret = $cookies{ 'token_secret' };
        my $oauth_token = $app->param( 'oauth_token' );
        my $verifier = $app->param( 'oauth_verifier' );
        my $scope = 'blog:' . $blog_id;
        my $consumer_key = $plugin->get_config_value( 'consumer_key', $scope );
        my $consumer_secret = $plugin->get_config_value( 'consumer_secret', $scope );
        my $access_token_url = 'http://twitter.com/oauth/access_token';
        my $request_method = 'POST';
        my $request = Net::OAuth->request( "access token" )->new(
            consumer_key => $consumer_key,
            consumer_secret => $consumer_secret,
            request_url => $access_token_url,
            request_method => $request_method,
            signature_method => 'HMAC-SHA1',
            timestamp => time,
            nonce => Digest::SHA1::sha1_base64( time . $$ . rand ),
            token => $oauth_token,
            verifier => $verifier,
            token_secret => $request_token_secret,
        );
        my $ua = LWP::UserAgent->new;
        my $http_header = HTTP::Headers->new( 'User-Agent' => $PLUGIN_NAME );
        my $http_request = HTTP::Request->new( $request_method, $access_token_url, $http_header, $request->to_post_body );
        my $res = $ua->request( $http_request );
        if ( $res->is_success ) {
            $param{ 'page_title' } = $plugin->translate( 'Get Access Token Success!' );
            my $test_post_uri = $app->base . $app->uri( mode => 'twitter_oauth_test', args => { blog_id => $blog_id } );
            $param{ 'msg' } = $plugin->translate( 'Get Access Token Success! <a href="[_1]">click to test post</a>.', $test_post_uri );
            $param{ 'is_success' } = 1;
            $param{ 'show_table' } = 1;
            my $response = Net::OAuth->response( 'access token' )->from_post_body( $res->content );
            if ( my $access_token = $response->token ) {
                $plugin->set_config_value( 'access_token', $access_token, $scope );
                $param{ 'access_token' } = $access_token;
            }
            if ( my $access_secret = $response->token_secret ) {
                $plugin->set_config_value( 'access_secret', $access_secret, $scope );
                $param{ 'access_secret' } = $access_secret;
            }
        }
    }
    unless ( $param{ 'is_success' } ) {
        $param{ 'page_title' } = $plugin->translate( 'Get Access Token failed!' );
        $param{ 'msg' } = $plugin->translate( 'Get Access Token failed!' );
    }
    $app->{ plugin_template_path } = File::Spec->catdir( $plugin->path,'tmpl' );
    my $tmpl = 'twitterbot_authorized.tmpl';
    return $app->build_page( $tmpl, \%param );
}

sub _cb_tp_twitterbot_config {
    my ( $cb, $app, $tmpl ) = @_;
    my ( $search, $replace );
    $search = quotemeta( '<[*mt_dir_uri*]>' );
    $replace = $app->base . $app->mt_path;
    $$tmpl =~ s/$search/$replace/g;
    $search = quotemeta( '<[*this_blog_id*]>' );
    $replace = $app->param( 'blog_id' );
    $$tmpl =~ s/$search/$replace/g;
}

sub _get_datetime {
    my ( $blog_id, $format ) = @_;
    my @tl = offset_time_list( time, $blog_id );
    my $ts = sprintf "%04d%02d%02d%02d%02d%02d", $tl[ 5 ]+1900, $tl[ 4 ]+1, @tl[ 3, 2, 1, 0 ];
    use MT::Template::Context;
    my $ctx = MT::Template::Context->new;
    my $datetime = $ctx->build_date( { ts => $ts,
                                       'format' => ( $format || "%Y-%m-%dT%H:%M:%S" ),
                                     }
                                   );
    return $datetime;
}

sub _shorten_url {
    my ( $message, $bitly_username, $bitly_api_key ) = @_;
    my $is_url = "(s?https?:\/\/[-_.!~*'()a-zA-Z0-9;\/?:\@&=+\$,%#]+)";
    my %url_list;
    my $i = 0;
    while ( $message =~ /$is_url/ ) {
        my $translated = '<[*url-' . $i . '*]>';
        if ( $message =~ s/$is_url/$translated/ ) {
            $url_list{ $translated } = { long_url => $1 };
            $i++;
        }
    }
    for my $key ( keys %url_list ) {
        if ( my $long_url = $url_list{ $key }->{ long_url } ) {
            my $short_url = _get_shorter_url( $long_url, $bitly_username, $bitly_api_key );
            my $search = quotemeta( $key );
            $message =~ s/$search/$short_url/;
        }
    }
    return $message;
}

sub _get_shorter_url {
    my ( $long_url, $bitly_username, $bitly_api_key ) = @_;
    my $check = quotemeta( 'http://bit.ly' );
    unless ( $long_url =~ /^$check/ ) {
        if ( $bitly_username && $bitly_api_key ) {
            my $ua = LWP::UserAgent->new( agent => $PLUGIN_NAME );
            my $bitly_api_url = "http://api.bit.ly/shorten";
            my $res = $ua->post( $bitly_api_url, [ 'history' => '1',
                                                   'version' => '2.0.1',
                                                   'longUrl' => $long_url,
                                                   'login' => $bitly_username,
                                                   'apiKey' => $bitly_api_key,
                                                 ]
                               );
            if ( $res->is_success ) {
                require JSON;
                if ( my $obj = JSON::from_json( $res->content ) ) {
                    unless ( $obj->{ errorCode } ) {
                        return $obj->{ results }->{ $long_url }->{ shortUrl };
                    }
                }
            }
        }
    }
    return $long_url;
}

sub _build_tmpl {
    my ( $text, $param, $blog_id ) = @_;
    return unless $text;
    return unless $blog_id;
    my $blog = MT->model( 'blog' )->load( { id => $blog_id } );
    return unless $blog;
    require MT::Template;
    require MT::Template::Context;
    my $tmpl = MT::Template->new;
    $tmpl->name( 'TwitterBot' );
    $tmpl->text( $text );
    $tmpl->blog_id( $blog_id );
    my $ctx = MT::Template::Context->new;
    $ctx->stash( 'blog', $blog );
    $ctx->stash( 'blog_id', $blog_id );
    my @tl = &offset_time_list( time, undef );
    my $ts = sprintf "%04d%02d%02d%02d%02d%02d", $tl[ 5 ] + 1900, $tl[ 4 ] + 1, @tl[ 3, 2, 1, 0 ];
    $ctx->{ current_timestamp } = $ts;
#     $ctx->{ __stash }->{ vars }->{ current_datetime } = $ts;
#     $ctx->{ __stash }->{ vars }->{ current_year } = $tl[ 5 ] + 1900;
#     $ctx->{ __stash }->{ vars }->{ current_month } = $tl[ 4 ] + 1;
#     $ctx->{ __stash }->{ vars }->{ current_day } = $tl[ 3 ];
#     $ctx->{ __stash }->{ vars }->{ current_hour } = $tl[ 2 ];
#     $ctx->{ __stash }->{ vars }->{ current_minute } = $tl[ 1 ];
#     $ctx->{ __stash }->{ vars }->{ current_second } = $tl[ 0 ];
#     $ctx->{ __stash }->{ vars }->{ current_wday } = wday_from_ts( $tl[ 5 ] + 1900, $tl[ 4 ] + 1, $tl[ 3 ] );
#     $ctx->{ __stash }->{ vars }->{ current_is_holiday } = isHoliday( $tl[ 5 ] + 1900, $tl[ 4 ] + 1, $tl[ 3 ], 1 );
    $param->{ current_datetime } = $ts;
    $param->{ current_year } = $tl[ 5 ] + 1900;
    $param->{ current_month } = $tl[ 4 ] + 1;
    $param->{ current_day } = $tl[ 3 ];
    $param->{ current_hour } = $tl[ 2 ];
    $param->{ current_minute } = $tl[ 1 ];
    $param->{ current_second } = $tl[ 0 ];
    $param->{ current_wday } = wday_from_ts( $tl[ 5 ] + 1900, $tl[ 4 ] + 1, $tl[ 3 ] );
    $param->{ current_is_holiday } = isHoliday( $tl[ 5 ] + 1900, $tl[ 4 ] + 1, $tl[ 3 ], 1 );
    for my $key ( keys %$param ) {
        $ctx->{ __stash }->{ vars }->{ $key } = $param->{ $key };
    }
    my $res = $tmpl->build( $ctx )
        or return MT->instance->error( MT->translate( $tmpl->errstr ) );
    return $res;
}

sub _save_success_log {
    my ( $message, $blog_id ) = @_;
    _save_log( $message, $blog_id, MT::Log::INFO() );
}

sub _save_error_log {
    my ( $message, $blog_id ) = @_;
    _save_log( $message, $blog_id, MT::Log::ERROR() );
}

sub _save_log {
    my ( $message, $blog_id, $log_level ) = @_;
    if ( $message ) {
        my $log = MT::Log->new;
        $log->message( $message );
        $log->class( 'twitterbot' );
        $log->blog_id( $blog_id );
        $log->level( $log_level );
        $log->save or die $log->errstr;
    }
}

sub _debug {
    my ( $data ) = @_;
    use Data::Dumper;
    MT->log( Dumper( $data ) );
}

1;
