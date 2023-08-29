require 'sinatra/base'
require 'mysql2'
require 'mysql2-cs-bind'
require 'erubis'
require 'redis'

module Ishocon2
  class AuthenticationError < StandardError; end
  class PermissionDenied < StandardError; end
end

class Ishocon2::WebApp < Sinatra::Base
  session_secret = ENV['ISHOCON2_SESSION_SECRET'] || 'showwin_happy'
  use Rack::Session::Cookie, key: 'rack.session', secret: session_secret
  set :erb, escape_html: true
  set :public_folder, File.expand_path('../public', __FILE__)
  set :protection, true

  PARTY = ['夢実現党', '国民10人大活躍党', '国民平和党', '国民元気党']

  helpers do
    def config
      @config ||= {
        db: {
          host: ENV['ISHOCON2_DB_HOST'] || 'localhost',
          port: ENV['ISHOCON2_DB_PORT'] && ENV['ISHOCON2_DB_PORT'].to_i,
          username: ENV['ISHOCON2_DB_USER'] || 'ishocon',
          password: ENV['ISHOCON2_DB_PASSWORD'] || 'ishocon',
          database: ENV['ISHOCON2_DB_NAME'] || 'ishocon2'
        }
      }
    end

    def db
      return $client if $client
      client = Mysql2::Client.new(
        host: config[:db][:host],
        port: config[:db][:port],
        username: config[:db][:username],
        password: config[:db][:password],
        database: config[:db][:database],
        reconnect: true
      )
      client.query_options.merge!(symbolize_keys: true)
      $client = client
    end

    def redis
      return $redis if $redis
      $redis = Redis.new(host: ENV['ISHOCON2_REDIS_HOST'] || 'localhost')
    end

    def db_initialize
      db.query('DELETE FROM votes')
    end

    def get_candidates
      return $candidates if $candidates
      $candidates = db.query('SELECT * FROM candidates')
    end

    def get_candidate(name)
      return nil if name.nil?
      val = redis.get("candidates.#{name}")
      return nil if val.nil?

      arr = val.split(':')
      {
        id: arr[0],
        name: name,
        political_party: arr[1],
        sex: arr[2]
      }
    end

    def setup_results
      get_candidates.each do |candidate|
        redis.set("candidates.#{candidate[:name]}", "#{candidate[:id]}:#{candidate[:political_party]}:#{candidate[:sex]}")
        redis.set("results.candidates.#{candidate[:id]}", 0)
        redis.keys("keywords.candidates.*").each { |k| redis.del(k) }
      end
      PARTY.each do |party|
        redis.set("results.party.#{party}", 0)
        redis.keys("keywords.party.*").each { |k| redis.del(k) }
      end
      redis.set("results.sex.男", 0)
      redis.set("results.sex.女", 0)
      redis.keys("users.votes.*").each { |k| redis.del(k) }
      # redis.keys("users.*").each { |k| redis.del(k) }
    end
  end

  get '/' do
    candidates = get_candidates

    candidates_ids = candidates.map {|c| c[:id] }
    results_keys = candidates_ids.map {|id| "results.candidates.#{id}" }
    results = redis.mget(results_keys)
    candidates.each_with_index do |candidate, i|
      candidate[:count] = results[i].to_i
    end
    candidates = candidates.sort_by { |c| c[:count] }.reverse

    candidate_results = []
    candidates.each_with_index do |r, i|
      # 上位10人と最下位のみ表示
      candidate_results.push(r) if i < 10 || 28 < i
    end

    parties = {}
    party_results_keys = PARTY.map { |party| "results.party.#{party}" }
    party_results = redis.mget(party_results_keys)
    PARTY.each_with_index { |party, i| parties[party] = party_results[i].to_i }

    sex_ratio = {
      '男': redis.get("results.sex.男").to_i,
      '女': redis.get("results.sex.女").to_i
    }

    erb :index, locals: { candidates: candidate_results,
                          parties: parties,
                          sex_ratio: sex_ratio }
  end

  get '/candidates/:id' do
    candidate = get_candidates.find { |c| c[:id] == params[:id].to_i }
    return redirect '/' if candidate.nil?
    votes = redis.get("results.candidates.#{candidate[:id]}").to_i
    keywords = redis.zrevrange("keywords.candidates.#{candidate[:id]}", 0, 10)

    erb :candidate, locals: { candidate: candidate,
                              votes: votes,
                              keywords: keywords }
  end

  get '/political_parties/:name' do
    votes = redis.get("results.party.#{params[:name]}").to_i
    candidates = get_candidates.select {|c| c[:political_party] == params[:name] }
    candidate_ids = candidates.map { |c| c[:id] }
    keywords = redis.zrevrange("keywords.party.#{params[:name]}", 0, 10)
    erb :political_party, locals: { political_party: params[:name],
                                    votes: votes,
                                    candidates: candidates,
                                    keywords: keywords }
  end

  get '/vote' do
    candidates = get_candidates
    erb :vote, locals: { candidates: candidates, message: '' }
  end

  post '/vote' do
    mynumber = params[:mynumber]
    vote_count = params[:vote_count].to_i

    user_hash = redis.get("users.#{mynumber}")
    user = if user_hash
      arr = user_hash.split(':')
      {
        name: arr[0],
        address: arr[1],
        votes: arr[2].to_i
      }
    else
      user = db.xquery('SELECT * FROM users WHERE mynumber = ?', params[:mynumber]).first
      if user
        user_hash = [user[:name], user[:address], user[:votes]].join(':')
        redis.set("users.#{mynumber}", user_hash)
      end
      user
    end

    candidate = if params[:candidate] && params[:candidate] != ''
      get_candidate(params[:candidate])
    else
      nil
    end

    voted_count = redis.get("users.votes.#{mynumber}").to_i

    if $template_cached.nil?
      candidates = get_candidates
      $invalid_user ||= erb :vote, locals: { candidates: candidates, message: '個人情報に誤りがあります' }
      $invalid_vote_count ||= erb :vote, locals: { candidates: candidates, message: '投票数が上限を超えています' }
      $invalid_candidate_blank ||= erb :vote, locals: { candidates: candidates, message: '候補者を記入してください' }
      $invalid_candidate ||= erb :vote, locals: { candidates: candidates, message: '候補者を正しく記入してください' }
      $invalid_keyword ||= erb :vote, locals: { candidates: candidates, message: '投票理由を記入してください' }
      $vote_success ||= erb :vote, locals: { candidates: candidates, message: '投票に成功しました' }
    end

    if user.nil?
      return $invalid_user
    # mynumberと名前とアドレスの一致を確認
    elsif user[:name] != params[:name] || user[:address] != params[:address]
      return $invalid_user
    elsif user[:votes] < (vote_count + voted_count)
      return $invalid_vote_count
    elsif params[:candidate].nil? || params[:candidate] == ''
      return $invalid_candidate_blank
    elsif candidate.nil?
      return $invalid_candidate
    elsif params[:keyword].nil? || params[:keyword] == ''
      return $invalid_keyword
    end

    redis.incrby("users.votes.#{mynumber}", vote_count)
    redis.incrby("results.candidates.#{candidate[:id]}", vote_count)
    redis.incrby("results.party.#{candidate[:political_party]}", vote_count)
    redis.incrby("results.sex.#{candidate[:sex]}", vote_count)
    redis.zincrby("keywords.candidates.#{candidate[:id]}", vote_count, params[:keyword])
    redis.zincrby("keywords.party.#{candidate[:political_party]}", vote_count, params[:keyword])

    return $vote_success
  end

  get '/initialize' do
    db_initialize
    get_candidates
    setup_results
    nil
  end

  get '/health' do
  end
end
