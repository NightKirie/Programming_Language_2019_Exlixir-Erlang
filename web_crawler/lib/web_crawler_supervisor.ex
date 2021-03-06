defmodule WebCrawlerSupervisor do
	@default_headers []
	@default_options [follow_redirect: true, ssl: [{:versions, [:"tlsv1.2"]}]]
	@default_url_front "https://arxiv.org/search/?query="
	@default_url_end "&searchtype=author&size=25&start="
  	def get_links() do
		author = 
			IO.gets("Input author: ")
			|> String.replace(" ", "+")
			|> String.replace("\n", "")
		url = URI.parse(@default_url_front <> author <> @default_url_end <> "0") 

		context = set_context()

		IO.puts "Process start time: " <> inspect(Time.utc_now)
		get_links(url, context)
		IO.puts "Process end time: " <> inspect(Time.utc_now)
  	end

	def set_context() do
		%{
			headers: @default_headers,
			options: @default_options
		}
	end

	defp get_links(url, context) do
		url
		|> to_string
		|> HTTPoison.get(context.headers, context.options)
		|> handle_response(url, context)
	end

	defp get_article_per_page(body) do
		body
		|> Floki.find("p.title")
		|> Enum.map(fn paper -> 
			paper
			|> Tuple.to_list()
			|> Enum.at(2)
			|> Enum.at(0)
			|> String.replace("\n", "")
			|> String.trim
			|> IO.puts
			end)	
	end

  	defp handle_response({:ok, %{body: body}}, url, context) do
		IO.puts("Crawling \"#{url}\"...")
		{resultPerPage, totalResult} =
		body
		# Find the line like "Showing 1–x of n results for author:"
		|> Floki.find("h1.title")
		# Get the tuple {tagName, classList, content} in return list
		|> hd
		# Change the tuple into list [tagName, classList, content]
		|> Tuple.to_list()
		# Get the content
		|> Enum.at(2)
		# Get the text in the content
		|> Enum.at(0)
		# Get all numbers in the text 
		|> (&Regex.scan(&2, &1)).(
				# Regular expression of number, return {:ok, "[0-9,]+"}
				Regex.compile("[0-9,]+")
				# Make tuple into list [:ok, "[0-9,]+"]
				|> Tuple.to_list()
				# Get compiled regular expression object                      
				|> Enum.at(1)
			)
		# Change 2-d list to 1-d list
		|> List.flatten()
		# Remove "1" in list, we don't need that
		|> tl
		# Remove "," from number larger than 999
		|> Enum.map(fn x -> String.replace(x, ",", "") end)
		|> List.to_tuple()
		IO.puts "Total " <> totalResult <> "pages, " <> resultPerPage <> " articles per page"
		# Set the sub pages to crawl
		page_link = 
		Enum.to_list(1..Kernel.trunc(String.to_integer(totalResult)/String.to_integer(resultPerPage)))	
		|> Enum.map(fn x -> 
			url
			|> URI.to_string
			|> String.replace("&searchtype=author&size=25&start=0", @default_url_end)
			|> Kernel.<>(Integer.to_string(x*25))
			end)

		# Initialize a parent supervisor to start crawling other pages
		WebCrawlerSupervisor.ParentSupervisor.start_link(page_link)
		
		# Get the article in the first page
		get_article_per_page(body)
	end

end

# Parent supervisor that supervise other sub supervisor
defmodule WebCrawlerSupervisor.ParentSupervisor do
	use Supervisor

	def start_link(page_link) do
		Supervisor.start_link(__MODULE__, page_link)
	end

	def init(page_link) do
		sub_supervisors = Enum.map(page_link, fn(link) ->
			worker(WebCrawlerSupervisor.SubSupervisor, [link], [id: link, restart: :temporary])
		end)
		supervise(sub_supervisors, strategy: :one_for_one)
	end
end

# Sub supervisor for each page crawling, prevent if that page can't crawl, won't bother other crawling processes
defmodule WebCrawlerSupervisor.SubSupervisor do
	use Supervisor

	def start_link(link) do
		Supervisor.start_link(__MODULE__, link, [max_restarts: 5, max_seconds: 600])
	end

	def init(link) do
		craw_sub_page = [ worker(WebCrawlerSupervisor.CrawlSubPage, [link], [id: link, restart: :transient]) ]
		supervise(craw_sub_page, strategy: :one_for_one)
		#children
	end
end

# Process for crawling a sub page
defmodule WebCrawlerSupervisor.CrawlSubPage do
	def start_link(link) do
		pid = spawn_link(__MODULE__, :init, [link])
		{:ok, pid}
	end

	def init(link) do
		IO.puts "Process start time: " <> inspect(Time.utc_now)
		crawl_page(link)
		IO.puts "Process end time: " <> inspect(Time.utc_now)
	end

	defp crawl_page(url) do
		context = WebCrawlerSupervisor.set_context()
		HTTPoison.get(url, context.headers, context.options)
		|> get_article_per_page
	end

	defp get_article_per_page({:ok, %{body: body}}) do
		body
		|> Floki.find("p.title")
		|> Enum.map(fn paper -> 
			paper
			|> Tuple.to_list()
			|> Enum.at(2)
			|> Enum.at(0)
			|> String.replace("\n", "")
			|> String.trim
			|> IO.puts
			end)	
	end
end