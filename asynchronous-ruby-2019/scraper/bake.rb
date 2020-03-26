
require 'sequel'
require 'fileutils'

require 'async'

require 'async/http/internet'
require 'async/semaphore'
require 'async/barrier'

require 'async/io/notification'

def initialize(context)
	super
	
	@database = Sequel.connect("postgres://localhost/rubygems")
	
	@cache_root = File.expand_path("cache", __dir__)
	@pattern = File.expand_path("*/*", @cache_root)
	@limit = 10_000
	
	@gems = @database.from(:gem_downloads).select_group(:name, :rubygem_id).select_more{sum(:count).as(:total)}.join(:rubygems, id: :rubygem_id).reverse_order(:total).limit(@limit)
end

def count
	installed_gems = Dir.glob(@pattern).map{|path| File.basename(path).rpartition('-').values_at(0, 2)}.to_h
	
	puts "#{installed_gems.size} installed gems."
	
	viable = 0
	
	Dir.glob(@pattern) do |path|
		lib_path = File.expand_path("lib", path)
		unless File.directory?(lib_path)
			puts "#{path} does not have `lib` directory!"
		end
		
		viable += 1
	end
	
	puts "Found #{viable} viable lib paths..."
end

def statistics
	top_downloads = @database.from(:gem_downloads).sum(:count)
	top_total = @gems.sum(:total)
	total = @database.from(:rubygems).count
	
	puts "There are #{total} gems in the database."
	
	puts "Top #{@limit} gems represents #{(@limit.to_f / total * 100.0).to_f.round(2)}% of all gems."
	puts "Top #{@limit} gems accounts for #{(top_total / top_downloads * 100.0).to_f.round(2)}% of all downloads."
	
	width = 10
	
	File.open("downloads.csv", "w") do |file|
		totals = @gems.map{|gem| gem[:total]}
		
		bins = totals.each_slice(width).map{|slice| slice.sum.to_i}
		
		bins.each{|value| file.puts value}
	end
	
	system("gnuplot downloads.gnuplot > downloads.svg")
end

def list
	installed_gems = Dir.glob(@pattern).map{|path| [File.basename(path).rpartition('-').first, path]}.to_h
	
	@gems.limit(1000).each do |gem|
		sum = Hash.new{|h,k| h[k] = 0}
		
		root = installed_gems[gem[:name]]
		source_files = File.expand_path("lib/**/*.rb", root)
		
		Dir.glob(source_files) do |path|
			begin
				code = File.read(path)
				
				# code.scan(/Thread|Mutex|\.synchronize/) do |match|
				code.scan(/\|\|= Mutex/) do |match|
					sum[match.to_s] += 1
				end
			rescue
				Async.logger.error(path, $!)
			end
		end
		
		unless sum.empty?
			puts "Gem: #{gem[:name]} has #{gem[:total].to_i} downloads."
			puts "\t#{root} #{sum}"
		end
	end
end

def fetch
	installed_gems = Dir.glob(@pattern).map{|path| [File.basename(path).rpartition('-').first, path]}.to_h
	
	puts "#{installed_gems.size} installed gems."
	
	puts "Considering #{gems.count} gems..."
	
	skipped = 0
	
	Async do
		semaphore = Async::Semaphore.new(10)
		barrier = Async::Barrier.new(parent: semaphore)
		
		@gems.each do |gem|
			if path = installed_gems[gem[:name]]
				skipped += 1
				
				lib_path = File.join(path, "lib")
				
				unless File.directory?(lib_path)
					puts "#{gem[:name]} doesn't have lib path... (#{gem})"
				end
				
				next
			end
			
			cache_path = File.expand_path(gem[:name][0...3], @cache_root)
			FileUtils.mkdir_p cache_path
			
			Async.logger.info "Fetching #{gem[:name]} which has #{gem[:total].to_i} downloads..."
			
			defer(parent: barrier) do
				sh("gem", "unpack", gem[:name], chdir: cache_path)
			end
		end
		
		barrier.wait
	end
	
	puts "Skipped #{skipped} gems."
end

def check
	installed_gems = Dir.glob(@pattern).map{|path| [File.basename(path).rpartition('-').first, path]}.to_h
	
	puts "Found #{installed_gems.size} gem directories"
	
	count = {
		gems: 0,
		files: 0
	}
	
	sums = {}
	
	@gems.each do |gem|
		puts "Considering #{gem[:name]} #{gem[:total].to_i} downloads..."
		root = installed_gems[gem[:name]]
		
		count[:gems] += 1
		sum = Hash.new{|h,k| h[k] = 0}
		
		source_files = File.expand_path("**/*.rb", root)
		
		Dir.glob(source_files) do |path|
			begin
				code = File.read(path)
				found = Hash.new{|h,k| h[k] = 0}
				
				code.scan(/Mutex|Monitor/) do |match|
					sum[match.to_s] += 1
					found[match.to_s] += 1
				end
				
				puts "\t#{path} #{found}" unless found.empty?
				count[:files] += 1
			rescue
				Async.logger.error(path, $!)
			end
		end
		
		unless sum.empty?
			puts "\t ** #{root} #{sum}"
			sums[root] = sum
		end
	end
	
	puts "Out of #{count[:gems]}, #{(sums.size.to_f / count[:gems] * 100.0).to_f.round(2)}% use Thread constructs explicitly."
end

private

def defer(*args, parent: Async::Task.current, &block)
	parent.async do
		notification = Async::IO::Notification.new
		
		thread = Thread.new(*args) do
			yield
		ensure
			notification.signal
		end
		
		notification.wait
		thread.join
	ensure
		notification.close
	end
end
