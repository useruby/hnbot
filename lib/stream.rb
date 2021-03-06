class Stream
  include MongoMapper::Document
  before_save :update_avatar_settings
  before_destroy :unwatch_avatar

  USER = 1; TREND = 2; KEYWORD = 3;

	AZSET = ("a".."z").to_a + ("A".."Z").to_a + (0..9).to_a
	AZLEN = AZSET.size

  key :sid, String    # mavenn stream id
  key :title, String
  key :config, Hash
  key :cache, Hash    # cache config in effect
  key :status, String, :default => "Active"

  key :mavenn, Boolean, :default => false
  key :posted_at, Time

  # activity as [ {actor, object, action} ]
  # options can be :avatar, or :since
  def tuples(options={})
    retval = []

    avatar = options[:avatar] || Avatar.first(:name => self.config[:user])
    return [] if not avatar

    points = self.config[:points] || 1
    actor = {:person => avatar.name}

    # There are two kinds of actions - comment and submit
    # The posting link is our object, regardless of the action. 
    # We will NOT aggregate multiple comments for a given object. 
    # For comment action, we will include parent comment if any
    
    newer = {}
    newer[:created_at.gte] = options[:since] if options[:since]
    #comments = avatar.comments.where(:pntx.gte => points).where(newer)
    # HN Redesign::Comments don't show points
    comments = avatar.comments.where(newer)
    
    comments = comments.sort(:posted_at.desc).limit(100).all
    
    submits = avatar.postings.where(newer).sort(:posted_at.desc).limit(100).all

    pmap = {nil => {}}
    pids = comments.map {|c| c.pid }
    postings = Posting.all(:pid => {"$in" => pids})
    postings.each {|p| pmap[p.pid] = p.objectify}

    cmap = {}
    cids = comments.map {|c| [c.parent_cid, c.contexts]}.uniq.flatten
    parents = Comment.all(:cid => {"$in" => cids})
    parents.each {|c| cmap[c.cid] = c.threadify}
                        
    #combined = interleave_by_posted_at(comments, postings)
    combined = comments + submits
    combined.each do |item| 
      action = item.actify
      object = pmap[item.pid] 
      object = item.objectify if !object && item.is_a?(Posting)
      thread = []
      if item.is_a?(Comment)
        item.contexts.push(item.parent_cid).uniq.each do |tcid|
          thread << cmap[tcid]
        end
        $stderr.puts "thread: #{item.text.slice(0..42)} #{thread}"
        action[:meta].update(:thread => thread)
      end
      retval << {:object => object, :action => action, :actor => actor}
    end
    retval
  end

  def interleave_by_posted_at(comments, postings)
    result = []

    while !comments.empty? and !postings.empty? do 
      cm = comments.shift
      ps = postings.shift
      item = if cm and ps 
        cm.posted_at > ps.posted_at ? cm : ps 
      else
        cm || ps
      end
      case item
      when Comment; postings.unshift(ps) if ps
      when Posting; comments.unshift(cm) if cm
      end
      result << item
    end
    result
  end

  def self.preview
    av = Avatar.first(:name => %w(pg patio11 tptacek).shuffle.shift)
    Stream.new.tuples(av)
  end
  
	def self.generate_stream_id(len=11)
		(1..len).map {AZSET[rand(AZLEN)]}.join
	end

  def self.invalidate(avatar)
    streams = Stream.all("cache.user" => avatar.name)
    Stream.set({:id => {"$in" => streams.map{|x| x.id}}}, :status => 'Invalid')
    avatar.unwatch(streams.size)
  end

  def update_avatar_settings
    previous = self.cache ? self.cache[:user] :nil
    Avatar.unwatch(previous) if previous
    self.cache[:user] = self.config[:user]
    Avatar.watch(self.cache[:user])
  end

  def unwatch_avatar
    Avatar.unwatch(self.cache[:user])
  end

end
