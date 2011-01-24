require 'puppet/external/dot'
require 'puppet/relationship'
require 'set'
require 'ostruct'

# A hopefully-faster graph class to replace the use of GRATR.
class Puppet::SimpleGraph
  #
  # All public methods of this class must maintain (assume ^ ensure) the following invariants, where "=~=" means
  # equiv. up to order:
  #
  #   @in_to.keys =~= @out_to.keys =~= all vertices
  #   @in_to.values.collect { |x| x.values }.flatten =~= @out_from.values.collect { |x| x.values }.flatten =~= all edges
  #   @in_to[v1][v2] =~= @out_from[v2][v1] =~= all edges from v1 to v2
  #   @in_to   [v].keys =~= vertices with edges leading to   v
  #   @out_from[v].keys =~= vertices with edges leading from v
  #   no operation may shed reference loops (for gc)
  #   recursive operation must scale with the depth of the spanning trees, or better (e.g. no recursion over the set
  #       of all vertices, etc.)
  #
  # This class is intended to be used with DAGs.  However, if the
  # graph has a cycle, it will not cause non-termination of any of the
  # algorithms.  The topsort method detects and reports cycles.
  #
  def initialize
    @in_to = {}
    @out_from = {}
    @upstream_from = {}
    @downstream_from = {}
  end

  # Clear our graph.
  def clear
    @in_to.clear
    @out_from.clear
    @upstream_from.clear
    @downstream_from.clear
  end

  # Which resources depend upon the given resource.
  def dependencies(resource)
    vertex?(resource) ? upstream_from_vertex(resource).keys : []
  end

  def dependents(resource)
    vertex?(resource) ? downstream_from_vertex(resource).keys : []
  end

  # Whether our graph is directed.  Always true.  Used to produce dot files.
  def directed?
    true
  end

  # Determine all of the leaf nodes below a given vertex.
  def leaves(vertex, direction = :out)
    tree_from_vertex(vertex, direction).keys.find_all { |c| adjacent(c, :direction => direction).empty? }
  end

  # Collect all of the edges that the passed events match.  Returns
  # an array of edges.
  def matching_edges(event, base = nil)
    source = base || event.resource

    unless vertex?(source)
      Puppet.warning "Got an event from invalid vertex #{source.ref}"
      return []
    end
    # Get all of the edges that this vertex should forward events
    # to, which is the same thing as saying all edges directly below
    # This vertex in the graph.
    @out_from[source].values.flatten.find_all { |edge| edge.match?(event.name) }
  end

  # Return a reversed version of this graph.
  def reversal
    result = self.class.new
    vertices.each { |vertex| result.add_vertex(vertex) }
    edges.each do |edge|
      result.add_edge edge.class.new(edge.target, edge.source, edge.label)
    end
    result
  end

  # Return the size of the graph.
  def size
    vertices.size
  end

  def to_a
    vertices
  end

  # This is a simple implementation of Tarjan's algorithm to find strongly
  # connected components in the graph; this is a fairly ugly implementation,
  # because I can't just decorate the vertices themselves.
  #
  # This method has an unhealthy relationship with the find_cycles_in_graph
  # method below, which contains the knowledge of how the state object is
  # maintained.
  def tarjan(root, s)
    # initialize the recursion stack we use to work around the nasty lack of a
    # decent Ruby stack.
    recur = [OpenStruct.new :node => root]

    while not recur.empty? do
      frame = recur.last
      v = frame.node
      case frame.step
      when nil then
        s.index[v]   = s.n
        s.lowlink[v] = s.n
        s.n          = s.n + 1

        s.s.push v

        frame.children = adjacent(v)
        frame.step = :children

      when :children then
        if frame.children.length > 0 then
          child = frame.children.shift
          if ! s.index[child] then
            # Never seen, need to recurse.
            frame.step = :after_recursion
            frame.child = child
            recur.push OpenStruct.new :node => child
          elsif s.s.member? child then
            # Performance note: the stack membership test *should* be done with a
            # constant time check, but I was lazy and used something that is
            # likely to be O(N) where N is the stack depth; this will bite us
            # eventually, and should be improved before the change lands.
            #
            # OTOH, this is only invoked on a very cold path, when things have
            # gone wrong anyhow, right now.  I feel that getting the code out is
            # worth more than that final performance boost. --daniel 2011-01-22
            s.lowlink[v] = [s.lowlink[v], s.index[child]].min
          end
        else
          if s.lowlink[v] == s.index[v] then
            # REVISIT: Surely there must be a nicer way to partition this around an
            # index, but I don't know what it is.  This works. :/ --daniel 2011-01-22
            #
            # Performance note: this might also suffer an O(stack depth) performance
            # hit, better replaced with something that is O(1) for splitting the
            # stack into parts.
            tmp = s.s.slice!(0, s.s.index(v))
            s.scc.push s.s
            s.s = tmp
          end
          recur.pop               # done with this node, finally.
        end

      when :after_recursion then
        s.lowlink[v] = [s.lowlink[v], s.lowlink[frame.child]].min
        frame.step = :children

      else
        fail "#{frame.step} is an unknown step"
      end
    end
  end

  # Find all cycles in the graph by detecting all the strongly connected
  # components, then eliminating everything with a size of one as
  # uninteresting - which it is, because it can't be a cycle. :)
  #
  # This has an unhealthy relationship with the 'tarjan' method above, which
  # it uses to implement the detection of strongly connected components.
  def find_cycles_in_graph
    state = OpenStruct.new :n => 0, :index => {}, :lowlink => {}, :s => [], :scc => []

    # we usually have a disconnected graph, must walk all possible roots
    vertices.each do |vertex|
      if ! state.index[vertex] then
        tarjan vertex, state
      end
    end

    return state.scc.select { |c| c.length > 1 }
  end

  # Perform a BFS on the sub graph representing the cycle, with a view to
  # generating a sufficient set of paths to report the cycle meaningfully, and
  # ideally usefully, for the end user.
  #
  # BFS is preferred because it will generally report the shortest paths
  # through the graph first, which are more likely to be interesting to the
  # user.  I think; it would be interesting to verify that. --daniel 2011-01-23
  def all_paths_in_cycle(cycle, max_paths = 10)
    raise ArgumentError, "negative or zero max_paths" if max_paths < 1

    # Calculate our filtered outbound vertex lists...
    adj = {}
    cycle.each do |vertex|
      adj[vertex] = adjacent(vertex).select{|s| cycle.member? s}
    end

    found = []

    stack = [OpenStruct.new :vertex => cycle.first, :path => []]
    while frame = stack.shift do
      if frame.path.member? frame.vertex then
        found << frame.path + [frame.vertex]

        # REVISIT: This should be an O(1) test, but I have no idea if Ruby
        # specifies Array#length to be O(1), O(n), or allows the implementer
        # to pick either option.  Should answer that. --daniel 2011-01-23
        break if found.length >= max_paths
      else
        adj[frame.vertex].each do |to|
          stack.push OpenStruct.new :vertex => to, :path => frame.path + [frame.vertex]
        end
      end
    end

    return found
  end

  def report_cycles_in_graph
    cycles = find_cycles_in_graph
    n = cycles.length           # where is "pluralize"? --daniel 2011-01-22
    s = n == 1 ? '' : 's'

    message = "Found #{n} dependency cycle#{s}:\n"
    cycles.each do |cycle|
      paths = all_paths_in_cycle(cycle)
      message += paths.map{ |path| '(' + path.join(" => ") + ')'}.join("\n") + "\n"
    end
    message += "Try the '--graph' option and opening the '.dot' file in OmniGraffle or GraphViz"

    raise Puppet::Error, message
  end

  # Provide a topological sort.
  def topsort
    degree = {}
    zeros = []
    result = []

    # Collect each of our vertices, with the number of in-edges each has.
    vertices.each do |v|
      edges = @in_to[v]
      zeros << v if edges.empty?
      degree[v] = edges.length
    end

    # Iterate over each 0-degree vertex, decrementing the degree of
    # each of its out-edges.
    while v = zeros.pop
      result << v
      @out_from[v].each { |v2,es|
        zeros << v2 if (degree[v2] -= 1) == 0
      }
    end

    # If we have any vertices left with non-zero in-degrees, then we've found a cycle.
    if cycles = degree.values.reject { |ns| ns == 0  } and cycles.length > 0
      report_cycles_in_graph
    end

    result
  end

  # Add a new vertex to the graph.
  def add_vertex(vertex)
    @in_to[vertex]    ||= {}
    @out_from[vertex] ||= {}
  end

  # Remove a vertex from the graph.
  def remove_vertex!(v)
    return unless vertex?(v)
    @upstream_from.clear
    @downstream_from.clear
    (@in_to[v].values+@out_from[v].values).flatten.each { |e| remove_edge!(e) }
    @in_to.delete(v)
    @out_from.delete(v)
  end

  # Test whether a given vertex is in the graph.
  def vertex?(v)
    @in_to.include?(v)
  end

  # Return a list of all vertices.
  def vertices
    @in_to.keys
  end

  # Add a new edge.  The graph user has to create the edge instance,
  # since they have to specify what kind of edge it is.
  def add_edge(e,*a)
    return add_relationship(e,*a) unless a.empty?
    @upstream_from.clear
    @downstream_from.clear
    add_vertex(e.source)
    add_vertex(e.target)
    @in_to[   e.target][e.source] ||= []; @in_to[   e.target][e.source] |= [e]
    @out_from[e.source][e.target] ||= []; @out_from[e.source][e.target] |= [e]
  end

  def add_relationship(source, target, label = nil)
    add_edge Puppet::Relationship.new(source, target, label)
  end

  # Find all matching edges.
  def edges_between(source, target)
    (@out_from[source] || {})[target] || []
  end

  # Is there an edge between the two vertices?
  def edge?(source, target)
    vertex?(source) and vertex?(target) and @out_from[source][target]
  end

  def edges
    @in_to.values.collect { |x| x.values }.flatten
  end

  def each_edge
    @in_to.each { |t,ns| ns.each { |s,es| es.each { |e| yield e }}}
  end

  # Remove an edge from our graph.
  def remove_edge!(e)
    if edge?(e.source,e.target)
      @upstream_from.clear
      @downstream_from.clear
      @in_to   [e.target].delete e.source if (@in_to   [e.target][e.source] -= [e]).empty?
      @out_from[e.source].delete e.target if (@out_from[e.source][e.target] -= [e]).empty?
    end
  end

  # Find adjacent edges.
  def adjacent(v, options = {})
    return [] unless ns = (options[:direction] == :in) ? @in_to[v] : @out_from[v]
    (options[:type] == :edges) ? ns.values.flatten : ns.keys
  end
  
  # Take container information from another graph and use it
  # to replace any container vertices with their respective leaves.
  # This creates direct relationships where there were previously
  # indirect relationships through the containers.
  def splice!(other, type)
    # We have to get the container list via a topological sort on the
    # configuration graph, because otherwise containers that contain
    # other containers will add those containers back into the
    # graph.  We could get a similar affect by only setting relationships
    # to container leaves, but that would result in many more
    # relationships.
    stage_class = Puppet::Type.type(:stage)
    whit_class  = Puppet::Type.type(:whit)
    containers = other.topsort.find_all { |v| (v.is_a?(type) or v.is_a?(stage_class)) and vertex?(v) }
    containers.each do |container|
      # Get the list of children from the other graph.
      children = other.adjacent(container, :direction => :out)

      # MQR TODO: Luke suggests that it should be possible to refactor the system so that
      #           container nodes are retained, thus obviating the need for the whit. 
      children = [whit_class.new(:name => container.name, :catalog => other)] if children.empty?

      # First create new edges for each of the :in edges
      [:in, :out].each do |dir|
        edges = adjacent(container, :direction => dir, :type => :edges)
        edges.each do |edge|
          children.each do |child|
            if dir == :in
              s = edge.source
              t = child
            else
              s = child
              t = edge.target
            end

            add_edge(s, t, edge.label)
          end

          # Now get rid of the edge, so remove_vertex! works correctly.
          remove_edge!(edge)
        end
      end
      remove_vertex!(container)
    end
  end

  # Just walk the tree and pass each edge.
  def walk(source, direction)
    # Use an iterative, breadth-first traversal of the graph. One could do
    # this recursively, but Ruby's slow function calls and even slower
    # recursion make the shorter, recursive algorithm cost-prohibitive.
    stack = [source]
    seen = Set.new
    until stack.empty?
      node = stack.shift
      next if seen.member? node
      connected = adjacent(node, :direction => direction)
      connected.each do |target|
        yield node, target
      end
      stack.concat(connected)
      seen << node
    end
  end

  # A different way of walking a tree, and a much faster way than the
  # one that comes with GRATR.
  def tree_from_vertex(start, direction = :out)
    predecessor={}
    walk(start, direction) do |parent, child|
      predecessor[child] = parent
    end
    predecessor
  end

  def downstream_from_vertex(v)
    return @downstream_from[v] if @downstream_from[v]
    result = @downstream_from[v] = {}
    @out_from[v].keys.each do |node|
      result[node] = 1
      result.update(downstream_from_vertex(node))
    end
    result
  end

  def upstream_from_vertex(v)
    return @upstream_from[v] if @upstream_from[v]
    result = @upstream_from[v] = {}
    @in_to[v].keys.each do |node|
      result[node] = 1
      result.update(upstream_from_vertex(node))
    end
    result
  end

  # LAK:FIXME This is just a paste of the GRATR code with slight modifications.

  # Return a DOT::DOTDigraph for directed graphs or a DOT::DOTSubgraph for an
  # undirected Graph.  _params_ can contain any graph property specified in
  # rdot.rb. If an edge or vertex label is a kind of Hash then the keys
  # which match +dot+ properties will be used as well.
  def to_dot_graph (params = {})
    params['name'] ||= self.class.name.gsub(/:/,'_')
    fontsize   = params['fontsize'] ? params['fontsize'] : '8'
    graph      = (directed? ? DOT::DOTDigraph : DOT::DOTSubgraph).new(params)
    edge_klass = directed? ? DOT::DOTDirectedEdge : DOT::DOTEdge
    vertices.each do |v|
      name = v.to_s
      params = {'name'     => '"'+name+'"',
        'fontsize' => fontsize,
        'label'    => name}
      v_label = v.to_s
      params.merge!(v_label) if v_label and v_label.kind_of? Hash
      graph << DOT::DOTNode.new(params)
    end
    edges.each do |e|
      params = {'from'     => '"'+ e.source.to_s + '"',
        'to'       => '"'+ e.target.to_s + '"',
        'fontsize' => fontsize }
      e_label = e.to_s
      params.merge!(e_label) if e_label and e_label.kind_of? Hash
      graph << edge_klass.new(params)
    end
    graph
  end

  # Output the dot format as a string
  def to_dot (params={}) to_dot_graph(params).to_s; end

  # Call +dotty+ for the graph which is written to the file 'graph.dot'
  # in the # current directory.
  def dotty (params = {}, dotfile = 'graph.dot')
    File.open(dotfile, 'w') {|f| f << to_dot(params) }
    system('dotty', dotfile)
  end

  # Produce the graph files if requested.
  def write_graph(name)
    return unless Puppet[:graph]

    Puppet.settings.use(:graphing)

    file = File.join(Puppet[:graphdir], "#{name}.dot")
    File.open(file, "w") { |f|
      f.puts to_dot("name" => name.to_s.capitalize)
    }
  end

  # This flag may be set to true to use the new YAML serialzation
  # format (where @vertices is a simple list of vertices rather than a
  # list of VertexWrapper objects).  Deserialization supports both
  # formats regardless of the setting of this flag.
  class << self
    attr_accessor :use_new_yaml_format
  end
  self.use_new_yaml_format = false

  # Stub class to allow graphs to be represented in YAML using the old
  # (version 2.6) format.
  class VertexWrapper
    attr_reader :vertex, :adjacencies
    def initialize(vertex, adjacencies)
      @vertex = vertex
      @adjacencies = adjacencies
    end

    def inspect
      { :@adjacencies => @adjacencies, :@vertex => @vertex.to_s }.inspect
    end
  end

  # instance_variable_get is used by Object.to_zaml to get instance
  # variables.  Override it so that we can simulate the presence of
  # instance variables @edges and @vertices for serialization.
  def instance_variable_get(v)
    case v.to_s
    when '@edges' then
      edges
    when '@vertices' then
      if self.class.use_new_yaml_format
        vertices
      else
        result = {}
        vertices.each do |vertex|
          adjacencies = {}
          [:in, :out].each do |direction|
            adjacencies[direction] = {}
            adjacent(vertex, :direction => direction, :type => :edges).each do |edge|
              other_vertex = direction == :in ? edge.source : edge.target
              (adjacencies[direction][other_vertex] ||= Set.new).add(edge)
            end
          end
          result[vertex] = Puppet::SimpleGraph::VertexWrapper.new(vertex, adjacencies)
        end
        result
      end
    else
      super(v)
    end
  end

  def to_yaml_properties
    other_vars = instance_variables.reject { |v| %w{@in_to @out_from @upstream_from @downstream_from}.include?(v) }
    (other_vars + %w{@vertices @edges}).sort.uniq
  end

  def yaml_initialize(tag, var)
    initialize()
    vertices = var.delete('vertices')
    edges = var.delete('edges')
    if vertices.is_a?(Hash)
      # Support old (2.6) format
      vertices = vertices.keys
    end
    vertices.each { |v| add_vertex(v) }
    edges.each { |e| add_edge(e) }
    var.each do |varname, value|
      instance_variable_set("@#{varname}", value)
    end
  end
end
