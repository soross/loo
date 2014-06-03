require 'sinatra'
require 'json'
require 'mongo'
require 'bson'
require 'haml'
require 'action_view'
require 'twitter'

include Mongo
include ActionView::Helpers::DateHelper

configure :production do
  env = JSON.parse(ENV["VCAP_SERVICES"])["mongodb-2.2"].first["credentials"]

  conn = MongoClient.new(env["hostname"], env["port"])
  db = conn.db(env["db"])
  db.authenticate(env["username"], env["password"])

  set :db, db
end

configure :development do
  conn = MongoClient.new("localhost", 27017)
  db = conn.db("myconf2014")

  set :db, db
end

configure do
  # Get Mongo collections
  locations = settings.db.collection("locations")
  checkins = settings.db.collection("checkins")
  tweets = settings.db.collection("tweets")

  if locations.count < 1
    baseLocations = [
      {"name" => "Main Pavilion", "slug" => "main-pavilion"},
      {"name" => "Northern Zone", "slug" => "north"},
      {"name" => "Southern Zone", "slug" => "south"},
      {"name" => "Eastern Zone 1", "slug" => "east-1"},
      {"name" => "Eastern Zone 2", "slug" => "east-2"},
      {"name" => "Western Zone 1", "slug" => "west-1"},
      {"name" => "Western Zone 2", "slug" => "west-2"}
    ]
    locations.insert(baseLocations)
  end

  # Connect to Twitter API
  twitter = Twitter::REST::Client.new do |config|
    config.consumer_key = ENV["TWITTER_CONSUMER_KEY"]
    config.consumer_secret = ENV["TWITTER_CONSUMER_SECRET"]
    config.access_token = ENV["TWITTER_ACCESS_TOKEN"]
    config.access_token_secret = ENV["TWITTER_ACCESS_TOKEN_SECRET"]
  end

  set :locations, locations
  set :checkins, checkins
  set :tweets, tweets
  set :twitter, twitter
end

get '/' do
  # Get 10 most recent checkins
  checkins = settings.checkins.find.sort(:timestamp => :desc).limit(10).to_a

  checkins.each do |checkin|
    # Get location details for the checkin
    checkin['location'] = settings.locations.find_one(:_id => checkin['location_id'])
  end

  haml :index, :locals => {:checkins => checkins}
end

get '/location' do
  # Get all locations
  locations = settings.locations.find.sort(:name).to_a
  locations.each do |location|
    # Get checkins for the location
    location['checkins'] = settings.checkins.find("location_id" => location["_id"]).to_a
  end

  haml :locations, :locals => {:locations => locations}
end

get '/location/:slug' do |s|
  # Lookup location by its URL slug
  location = settings.locations.find_one("slug" => s)

  # Get checkins for the location
  checkins = settings.checkins.find("location_id" => location["_id"]).sort(:timestamp => :desc).to_a

  haml :location, :locals => {:location => location, :checkins => checkins}
end

get '/checkin' do
  # Get a list of locations for the dropdown
  locations = settings.locations.find.sort(:name).to_a

  haml :checkin, :locals => {:locations => locations, :error => params[:error]}
end

post '/checkin' do
  username = params[:twitter_username]
  location_id = params[:location]

  begin
    if username.length > 0 && location_id.length > 0
      user = settings.twitter.user(username, {:skip_status => true})
      profile_image_url = user.profile_image_uri(:bigger).to_s      

      # Check if user has checked in before
      checkin = settings.checkins.find_one(:twitter_username => username)

      if(checkin)
        # Update existing checkin
        checkin['location_id'] = BSON::ObjectId(location_id)
        checkin['timestamp'] = Time.now
        settings.checkins.update({"_id" => checkin["_id"]}, checkin)
      else
        # Insert new checkin
        checkin = {
          :twitter_username => username, 
          :twitter_pic => profile_image_url, 
          :twitter_url => user.uri.to_s, 
          :location_id => BSON::ObjectId(location_id), 
          :timestamp => Time.now
        }
        settings.checkins.insert(checkin)
      end

      # Get location details
      location = settings.locations.find_one(:_id => BSON::ObjectId(location_id))

      # Redirect to location page
      redirect "/location/#{location['slug']}"
    else
      # Return to checkin page and display error
      redirect "/checkin?error=1"
    end
  rescue Twitter::Error
    # Return if an error is encountered using Twitter API
    redirect "/checkin?error=1"
  end
end

get '/tweets' do
  # Get one tweet from the database to check if we need to fetch new tweets
  tweet = settings.tweets.find_one
  tweet ? minutes = (Time.now - tweet['retrieved_at']).to_i / 60 : 0

  if(!tweet || minutes > 5)
    # Get new tweets
    newTweets = settings.twitter.search("#myconf2014", :result_type => "recent").take(10).to_a

    # Remove cached tweets from DB
    settings.tweets.remove

    newTweets.each do |t|
      tweet = {
        :twitter_username => t.user.screen_name,
        :user_url => t.user.uri.to_s,
        :user_name => t.user.name,
        :twitter_pic => t.user.profile_image_url.to_s,
        :text => t.text,
        :tweet_time => t.created_at,
        :retrieved_at => Time.now
      }
      # Cache each tweet into DB
      settings.tweets.insert(tweet)
    end

    # Reset minutes since last updated to zero
    minutes = 0
  end

  # Get tweets from DB
  tweets = settings.tweets.find.sort(:tweet_time => :desc).limit(10).to_a

  haml :tweets, :locals => {:tweets => tweets, :updated => minutes}
end