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
      return Thread.current[:ishocon2_db] if Thread.current[:ishocon2_db]
      client = Mysql2::Client.new(
        host: config[:db][:host],
        port: config[:db][:port],
        username: config[:db][:username],
        password: config[:db][:password],
        database: config[:db][:database],
        reconnect: true
      )
      client.query_options.merge!(symbolize_keys: true)
      Thread.current[:ishocon2_db] = client
      client
    end

    def redis
      return Thread.current[:ishocon2_redis] if Thread.current[:ishocon2_redis]
      client = Redis.new(host: ENV['ISHOCON2_REDIS_HOST'] || 'localhost')
      Thread.current[:ishocon2_redis] = client
      client
    end

#     def election_results
#       query = <<SQL
# SELECT c.id, c.name, c.political_party, c.sex, v.count
# FROM candidates AS c
# LEFT OUTER JOIN
#   (SELECT candidate_id, COUNT(*) AS count
#   FROM votes
#   GROUP BY candidate_id) AS v
# ON c.id = v.candidate_id
# ORDER BY v.count DESC
# SQL
#       db.xquery(query)
#     end

#     def voice_of_supporter(candidate_ids)
#       query = <<SQL
# SELECT keyword
# FROM votes
# WHERE candidate_id IN (?)
# GROUP BY keyword
# ORDER BY COUNT(*) DESC
# LIMIT 10
# SQL
#       db.xquery(query, candidate_ids).map { |a| a[:keyword] }
#     end

    def db_initialize
      db.query('DELETE FROM votes')
    end

    def get_candidates
      return Thread.current[:ishocon2_candidates] if Thread.current[:ishocon2_candidates]
      candidates = db.query('SELECT * FROM candidates')
      Thread.current[:ishocon2_candidates] = candidates
      candidates
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

    candidates.each do |candidate|
      candidate[:count] = redis.get("results.candidates.#{candidate[:id]}").to_i
    end
    candidates = candidates.sort_by { |c| c[:count] }.reverse

    candidate_results = []
    candidates.each_with_index do |r, i|
      # 上位10人と最下位のみ表示
      candidate_results.push(r) if i < 10 || 28 < i
    end

    parties = {}
    PARTY.each { |party|
      parties[party] = redis.get("results.party.#{party}").to_i
    }

    sex_ratio = {
      '男': redis.get("results.sex.男").to_i,
      '女': redis.get("results.sex.女").to_i
    }

    erb :index, locals: { candidates: candidate_results,
                          parties: parties,
                          sex_ratio: sex_ratio }
  end

  get '/candidates/:id' do
    # candidate = db.xquery('SELECT * FROM candidates WHERE id = ?', params[:id]).first
    candidate = get_candidates.find { |c| c[:id] == params[:id].to_i }
    return redirect '/' if candidate.nil?
    # votes = db.xquery('SELECT COUNT(*) AS count FROM votes WHERE candidate_id = ?', params[:id]).first[:count]
    votes = redis.get("results.candidates.#{candidate[:id]}").to_i
    # keywords = voice_of_supporter([params[:id]])
    keywords = redis.zrevrange("keywords.candidates.#{candidate[:id]}", 0, 10)

    erb :candidate, locals: { candidate: candidate,
                              votes: votes,
                              keywords: keywords }
  end

  get '/political_parties/:name' do
    # votes = 0
    # election_results.each do |r|
    #   votes += r[:count] || 0 if r[:political_party] == params[:name]
    # end
    votes = redis.get("results.party.#{params[:name]}").to_i
    # candidates = db.xquery('SELECT * FROM candidates WHERE political_party = ?', params[:name])
    candidates = get_candidates.select {|c| c[:political_party] == params[:name] }
    candidate_ids = candidates.map { |c| c[:id] }
    # keywords = voice_of_supporter(candidate_ids)
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
    # user = db.xquery('SELECT * FROM users WHERE mynumber = ?', params[:mynumber]).first
    mynumber = params[:mynumber]
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

    candidates = get_candidates

    candidate = if params[:candidate] && params[:candidate] != ''
      get_candidate(params[:candidate])
    else
      nil
    end
    # candidate = db.xquery('SELECT * FROM candidates WHERE name = ?', params[:candidate]).first

    voted_count = redis.get("users.votes.#{mynumber}").to_i
    # voted_count =
    #   user.nil? ? 0 : db.xquery('SELECT COUNT(*) AS count FROM votes WHERE user_id = ?', user[:id]).first[:count]

    if user.nil?
      return erb :vote, locals: { candidates: candidates, message: '個人情報に誤りがあります' }
    # mynumberと名前とアドレスの一致を確認
    elsif user[:name] != params[:name] || user[:address] != params[:address]
      return erb :vote, locals: { candidates: candidates, message: '個人情報に誤りがあります' }
    elsif user[:votes] < (params[:vote_count].to_i + voted_count)
      return erb :vote, locals: { candidates: candidates, message: '投票数が上限を超えています' }
    elsif params[:candidate].nil? || params[:candidate] == ''
      return erb :vote, locals: { candidates: candidates, message: '候補者を記入してください' }
    elsif candidate.nil?
      return erb :vote, locals: { candidates: candidates, message: '候補者を正しく記入してください' }
    elsif params[:keyword].nil? || params[:keyword] == ''
      return erb :vote, locals: { candidates: candidates, message: '投票理由を記入してください' }
    end

    # params[:vote_count].to_i.times do
    #   result = db.xquery('INSERT INTO votes (user_id, candidate_id, keyword) VALUES (?, ?, ?)',
    #             user[:id],
    #             candidate[:id],
    #             params[:keyword])
    # end

    vote_count = params[:vote_count].to_i

    result_candidate = redis.get("results.candidates.#{candidate[:id]}").to_i
    result_party = redis.get("results.party.#{candidate[:political_party]}").to_i
    result_sex = redis.get("results.sex.#{candidate[:sex]}").to_i

    redis.set("users.votes.#{mynumber}", voted_count + vote_count)

    redis.set("results.candidates.#{candidate[:id]}", result_candidate + vote_count)
    redis.set("results.party.#{candidate[:political_party]}", result_party + vote_count)
    redis.set("results.sex.#{candidate[:sex]}", result_sex + vote_count)

    redis.zadd("keywords.candidates.#{candidate[:id]}", redis.zscore("keywords.candidates.#{candidate[:id]}", params[:keyword]).to_i + vote_count, params[:keyword])
    redis.zadd("keywords.party.#{candidate[:political_party]}", redis.zscore("keywords.party.#{candidate[:political_party]}", params[:keyword]).to_i + vote_count, params[:keyword])

    return erb :vote, locals: { candidates: candidates, message: '投票に成功しました' }
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
