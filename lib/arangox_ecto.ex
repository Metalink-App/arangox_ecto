defmodule ArangoXEcto do
  @moduledoc """
  Methods for interacting with ArangoDB that aren't through Ecto.

  This allows for easy interaction with graph functions of Arango. Using Ecto's relations for edge relations was tried
  but it was found to be too much of a 'hacky' solution. Using separate functions that still utilise Ecto document
  queries was found to be the optimal solution.
  """

  import Ecto.Query, only: [from: 2]

  alias ArangoXEcto.Edge

  @type query :: binary()
  @type vars :: keyword() | map()
  @type mod :: Ecto.Schema.t()

  @doc """
  Runs a raw AQL query on the database.

  This will create a transaction and cursor on Arango and run the raw query.

  If there is an error in the query such as a syntax error, an `Arangox.Error` will be raised.

  ## Parameters

  - `repo` - The Ecto repo module to use for queries
  - `query` - The AQL query string to execute
  - `vars` - A keyword list or a map with the values for variables in the query
  - `opts` - Options to be passed to `DBConnection.transaction/3`

  ## Examples

      iex> ArangoXEcto.aql_query(
            Repo,
            "FOR var in users FILTER var.first_name == @fname AND var.last_name == @lname RETURN var",
            fname: "John",
            lname: "Smith"
          )
      {:ok,
      [
        %{
          "_id" => "users/12345",
          "_key" => "12345",
          "_rev" => "_bHZ8PAK---",
          "first_name" => "John",
          "last_name" => "Smith"
        }
      ]}
  """
  @spec aql_query(Ecto.Repo.t(), query(), vars(), [DBConnection.option()]) ::
          {:ok, list(map)} | {:error, any()}
  def aql_query(repo, query, vars \\ [], opts \\ []) do
    conn = gen_conn_from_repo(repo)

    {query, vars} = process_vars(query, vars)

    Arangox.transaction(
      conn,
      fn cursor ->
        stream = Arangox.cursor(cursor, query, vars)

        Enum.reduce(stream, [], fn resp, acc ->
          acc ++ resp.body["result"]
        end)
      end,
      opts
    )
  end

  @doc """
  Runs an Arangox function using a repo

  This is simply a helper function that extracts the connection from the repo and runs a regular query.

  ## Parameters

  - `repo` - The Ecto repo module used for connection
  - `function` - An atom of the Arangox function to run
  - `args` - The options passed to the function (not including the conn argument)

  The `conn` argument is automatically prepended to your supplied `args`

  ## Supported Functions

  - `:abort`
  - `:cursor`
  - `:delete`
  - `:delete!`
  - `:get`
  - `:get!`
  - `:head`
  - `:head!`
  - `:options`
  - `:options!`
  - `:patch`
  - `:patch!`
  - `:post`
  - `:post!`
  - `:put`
  - `:put!`
  - `:request`
  - `:request!`
  - `:run`
  - `:status`
  - `:transaction` (use built in `Ecto.Repo.transaction/2` instead)

  ## Examples

      iex> ArangoXEcto.api_query(Repo, :get, ["/_api/collection"])
      {:ok, %Arangox.Response{body: ...}}

      iex> ArangoXEcto.api_query(Repo, :non_existent, ["/_api/collection"])
      ** (ArgumentError) Invalid function passed to `Arangox` module

  """
  @allowed_arangox_funcs [
    :abort,
    :cursor,
    :delete,
    :delete!,
    :get,
    :get!,
    :head,
    :head!,
    :options,
    :options!,
    :patch,
    :patch!,
    :post,
    :post!,
    :put,
    :put!,
    :request,
    :request!,
    :run,
    :status,
    :transaction
  ]
  @spec api_query(mod(), atom(), list()) :: {:ok, Arangox.Response.t()} | {:error, any()}
  def api_query(repo, function, args \\ []) do
    conn = gen_conn_from_repo(repo)

    if function in @allowed_arangox_funcs and
         function in Keyword.keys(Arangox.__info__(:functions)) do
      apply(Arangox, function, [conn | args])
    else
      raise ArgumentError, "Invalid function passed to `Arangox` module"
    end
  end

  @doc """
  Creates an edge between two modules

  This can create an edge collection dynamically if no additional fields are required,
  otherwise an edge schema needs to be specified.

  The collection name can be passed as an option or is obtained from the provided schema,
  otherwise it is generated dynamically.

  Since ArangoDB does not care about the order of the from and two options in anonymous graphs, the order of the
  from and to attributes used in this function will work either way.

  ## Parameters

  - `repo` - The Ecto repo module to use for queries
  - `from` - The Ecto Schema struct to use for the from vertex
  - `to` - The Ecto Schema struct to use for the to vertex
  - `opts` - Options to use

  ## Options

  Accepts the following options:

  - `:edge` - A specific edge module to use for the edge. This is required for any additional fields on the edge. Overrides `collection_name`.
  - `:fields` - The values of the fields to set on the edge. Requires `edge` to be set otherwise it is ignored.
  - `:collection_name` - The name of the collection to use.

  ## Examples

      iex> ArangoXEcto.create_edge(Repo, user1, user2)
      %UserUser{_from: "users/12345", _to: "users/54321"}

  Create an edge with a specific edge collection name

      iex> ArangoXEcto.create_edge(Repo, user1, user2, collection_name: "friends")
      %Friends{_from: "users/12345", _to: "users/54321"}

  Create a edge schema and use it to create an edge relation

      defmodule UserPosts do
        use ArangoXEcto.Edge,
            from: User,
            to: Post

        import Ecto.Changeset

        schema "user_posts" do
          edge_fields()

          field(:type, :string)
        end

        def changeset(edge, attrs) do
          edges_changeset(edge, attrs)
          |> cast(attrs, [:type])
          |> validate_required([:type])
        end
      end

      iex> ArangoXEcto.create_edge(Repo, user1, user2, edge: UserPosts, fields: %{type: "wrote"})
      %UserPosts{_from: "users/12345", _to: "users/54321", from: #Ecto.Association.NotLoaded<association :from is not loaded>, to: #Ecto.Association.NotLoaded<association :to is not loaded>, type: "wrote"}

  """
  @spec create_edge(Ecto.Repo.t(), mod(), mod(), keyword()) ::
          {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def create_edge(repo, from, to, opts \\ [])

  def create_edge(repo, from, to, opts) do
    from_id = struct_id(from)
    to_id = struct_id(to)

    Keyword.get(opts, :edge, edge_module(from, to, opts))
    |> do_create_edge(repo, from_id, to_id, opts)
  end

  @doc """
  Deletes all edges matching matching the query

  If the `:conditions` option is set then those conditions must be true to delete.

  To just delete one edge do so like any other Ecto Schema struct, i.e. using `Ecto.Repo` methods.

  ## Parameters

  - `repo` - The Ecto repo module to use for queries
  - `from` - The Ecto Schema struct to use for the from vertex
  - `to` - The Ecto Schema struct to use for the to vertex
  - `opts` - Options to use

  ## Options

  Accepts the following options:

  - `:edge` - A specific edge module to use for the edge. This is required for any additional fields on the edge. Overrides `:collection_name`.
  - `:collection_name` - The name of the collection to use.
  - `:conditions` - A keyword list of conditions to filter for edge deletion

  ## Examples

  Deletes all edges from user1 to user2

      iex> ArangoXEcto.delete_all_edges(Repo, user1, user2)
      :ok

  Deletes all edges from user1 to user2 in specific collection

      iex> ArangoXEcto.delete_all_edges(Repo, user1, user2, collection_name: "friends")
      :ok

  Deletes all edges from user1 to user2 that have matching conditions

      iex> ArangoXEcto.delete_all_edges(Repo, user1, user2, conditions: [type: "best_friend"])
      :ok
  """
  @spec delete_all_edges(Ecto.Repo.t(), mod(), mod(), keyword()) :: :ok
  def delete_all_edges(repo, from, to, opts \\ [])

  def delete_all_edges(repo, from, to, [edge: edge_module] = opts) do
    from_id = struct_id(from)
    to_id = struct_id(to)

    edge_module
    |> do_delete_all_edges(repo, from_id, to_id, opts)
  end

  def delete_all_edges(repo, from, to, opts) do
    from_id = struct_id(from)
    to_id = struct_id(to)

    edge_module(from, to, opts)
    |> do_delete_all_edges(repo, from_id, to_id, opts)
  end

  @doc """
  Gets an ID from a schema struct

  ## Parameters

  - `struct` - The Ecto struct

  ## Example

  If the User schema's collection name is `users` the following would be:

      iex> user = %User{id: "123456"}
      %User{id: "123456"}

      iex> ArangoXEcto.get_id_from_struct(user)
      "users/123456"
  """
  @spec get_id_from_struct(mod()) :: binary()
  def get_id_from_struct(struct) when is_map(struct) or is_binary(struct), do: struct_id(struct)

  @doc """
  Gets an ID from a module and a key

  ## Parameters

  - `module` - Module to get the collection name from
  - `key` - The `_key` to use in the id

  ## Example

      iex> ArangoXEcto.get_id_from_module(User, "123456")
      "users/123456"
  """
  @spec get_id_from_module(Ecto.Schema.t(), binary()) :: binary()
  def get_id_from_module(module, key) when is_atom(module) and (is_atom(key) or is_binary(key)) do
    schema_type!(module)

    to_string(module.__schema__(:source)) <> "/" <> to_string(key)
  end

  def get_id_from_module(_, _), do: raise(ArgumentError, "Invalid module or key")

  @doc """
  Converts raw output of a query into a struct

  Transforms string map arguments into atom key map, adds id key and drops `_id`, `_key` and `_rev` keys.
  Then it creates a struct from filtered arguments using module.

  If a list of maps are passed then the maps are enumerated over.

  ## Parameters

  - `maps` - List of maps or singular map to convert to a struct
  - `module` - Module to use for the struct

  ## Example

      iex> {:ok, users} = ArangoXEcto.aql_query(
            Repo,
            "FOR user IN users RETURN user"
          )
      {:ok,
      [
        %{
          "_id" => "users/12345",
          "_key" => "12345",
          "_rev" => "_bHZ8PAK---",
          "first_name" => "John",
          "last_name" => "Smith"
        }
      ]}

      iex> ArangoXEcto.raw_to_struct(users, User)
      [
        %User{
          id: "12345",
          first_name: "John",
          last_name: "Smith"
        }
      ]
  """
  @spec raw_to_struct(map() | [map()], Ecto.Schema.t()) :: struct()
  def raw_to_struct(map, module) when is_list(map) and is_atom(module) do
    Enum.map(map, &raw_to_struct(&1, module))
  end

  def raw_to_struct(%{"_id" => _id, "_key" => _key} = map, module)
      when is_map(map) and is_atom(module) do
    schema_type!(module)

    args =
      patch_map(map)
      |> filter_keys_for_struct()

    struct(module, args)
  end

  def raw_to_struct(_, _), do: raise(ArgumentError, "Invalid input map or module")

  @doc """
  Generates a edge schema dynamically

  If a collection name is not provided one will be dynamically generated. The naming convention
  is the names of the two modules is alphabetical order. E.g. `User` and `Post` will combine for a collection
  name of `post_user` and an edge module name of `PostUser`. This order is used to prevent duplicates if the
  from and to orders are switched.

  This will create the Ecto Module in the environment dynamically. It will create it under the closest
  common parent module of the passed modules plus the `Edges` alias. For example, if the modules were
  `MyApp.Apple.User` and `MyApp.Apple.Banana.Post` then the edge would be created at `MyApp.Apple.Edges.PostUser`.

  Returns the Edge Module name as an atom.

  ## Parameters

  - `from_module` - Ecto Schema Module for the from part of the edge
  - `to_module` - Ecto Schema Module for the to part of the edge
  - `opts` - Options passed for module generation

  ## Options

  - `:collection_name` - The name of collection to use instead of generating it

  ## Examples

      iex> ArangoXEcto.edge_module(MyProject.User, MyProject.Company, [collection_name: "works_for"])
      MyProject.WorksFor

      iex> ArangoXEcto.edge_module(MyProject.User, MyProject.Company)
      MyProject.UsersCompanies
  """
  @spec edge_module(mod(), mod(), keyword()) :: atom()
  def edge_module(from_module, to_module, opts \\ [])

  def edge_module(%from_module{}, %to_module{}, opts),
    do: edge_module(from_module, to_module, opts)

  def edge_module(from_module, to_module, opts) do
    case Keyword.fetch(opts, :collection_name) do
      {:ok, name} -> name
      :error -> gen_edge_collection_name(from_module, to_module)
    end
    |> create_edge_module(from_module, to_module, opts)
  end

  @doc """
  Checks if a collection exists

  This will return true if the collection exists in the database, matches the specified type and is not a system
  database, otherwise it will be false.

  ## Parameters

  - `repo` - The Ecto repo module to use for the query
  - `collection_name` - Name of the collection to check
  - `type` - The type of collection to check against, defaults to a regular document

  ## Examples

  Checking a document collection exists

      iex> ArangoXEcto.collection_exists?(Repo, :users)
      true

  Checking an edge collection exists

      iex> ArangoXEcto.collection_exists?(Repo, "my_edge", :edge)
      true

  Checking a system document collection exists does not work

      iex> ArangoXEcto.collection_exists?(Repo, "_system_test")
      false
  """
  @spec collection_exists?(Ecto.Repo.t() | pid(), binary() | atom(), atom() | integer()) ::
          boolean()
  def collection_exists?(repo_or_conn, collection_name, type \\ :document)
      when is_binary(collection_name) or is_atom(collection_name) do
    conn = gen_conn_from_repo(repo_or_conn)

    Arangox.get(conn, "/_api/collection/#{collection_name}")
    |> case do
      {:ok, %Arangox.Response{body: %{"isSystem" => false} = body}} ->
        if is_nil(type) do
          true
        else
          Map.get(body, "type") == collection_type_to_integer(type)
        end

      _any ->
        false
    end
  end

  @doc """
  Returns if a Schema is an edge or not

  Checks for the presence of the `__edge__/0` function on the module.
  """
  @spec is_edge?(atom()) :: boolean()
  def is_edge?(module) when is_atom(module), do: function_exported?(module, :__edge__, 0)

  def is_edge?(_), do: false

  @doc """
  Returns if a Schema is a document schema or not

  Checks for the presence of the `__schema__/1` function on the module and not an edge.
  """
  @spec is_document?(atom()) :: boolean()
  def is_document?(module) when is_atom(module),
    do: function_exported?(module, :__schema__, 1) and not is_edge?(module)

  def is_document?(_), do: false

  @doc """
  Returns the type of a module

  This is just a shortcut to using `is_edge/1` and `is_document/1`. If it is neither nil is returned.

  ## Examples

  A real edge schema

      iex> ArangoXEcto.schema_type(MyApp.RealEdge)
      :edge

  Some module that is not an Ecto schema

      iex> ArangoXEcto.schema_type(MyApp.RandomModule)
      nil
  """
  @spec schema_type(atom()) :: :document | :edge | nil
  def schema_type(module) do
    cond do
      is_edge?(module) -> :edge
      is_document?(module) -> :document
      true -> nil
    end
  end

  @doc """
  Same as schema_type/1 but throws an error on none

  This is just a shortcut to using `is_edge/1` and `is_document/1`. If it is neither an error is raised.

  ## Examples

  A real edge schema

      iex> ArangoXEcto.schema_type!(MyApp.RealEdge)
      :edge

  Some module that is not an Ecto schema

      iex> ArangoXEcto.schema_type!(MyApp.RandomModule)
      ** (ArgumentError) Not an Ecto Schema
  """
  @spec schema_type!(atom()) :: :document | :edge
  def schema_type!(module) do
    schema_type(module)
    |> case do
      nil -> raise ArgumentError, "Not an Ecto Schema"
      any -> any
    end
  end

  ###############
  ##  Helpers  ##
  ###############

  defp gen_conn_from_repo(repo_or_conn) do
    case repo_or_conn do
      pid when is_pid(pid) ->
        pid

      repo ->
        %{pid: conn} = Ecto.Adapter.lookup_meta(repo)

        conn
    end
  end

  defp do_create_edge(module, repo, id1, id2, opts) do
    module
    |> validate_ecto_schema()
    |> validate_edge_module()
    |> maybe_create_edges_collection(repo)
    |> ensure_collections_exists!(repo, id1, id2)
    |> edge_changeset(id1, id2, opts)
    |> repo.insert!()
  end

  defp do_delete_all_edges(module, repo, from_id, to_id, opts) do
    module
    |> validate_ecto_schema()
    |> validate_edge_module()
    |> source_name()
    |> collection_exists!(repo, 3)

    module
    |> find_edge_by_nodes(repo, from_id, to_id, opts)
    |> Enum.each(&repo.delete/1)
  end

  defp find_edge_by_nodes(module, repo, from_id, to_id, opts) do
    conditions =
      Keyword.get(opts, :conditions, [])
      |> Keyword.merge(_from: from_id, _to: to_id)

    query =
      from(module,
        where: ^conditions
      )

    repo.all(query)
  end

  defp ensure_collections_exists!(module, repo, id1, id2) do
    collection_from_id(id1)
    |> collection_exists!(repo)

    collection_from_id(id2)
    |> collection_exists!(repo)

    module
  end

  defp collection_exists!(collection_name, repo, type \\ 2) do
    case collection_exists?(repo, collection_name, type) do
      true ->
        true

      false ->
        raise "Collection #{collection_name} does not exist"
    end
  end

  defp collection_from_id(id), do: source_name(id)

  defp create_edge_module(collection_name, from_module, to_module, opts) do
    project_prefix = Module.concat(common_parent_module(from_module, to_module), "Edges")
    module_name = Module.concat(project_prefix, Macro.camelize(collection_name))

    unless Keyword.get(opts, :create, true) == false or
             function_exported?(module_name, :__info__, 1) do
      contents =
        quote do
          use ArangoXEcto.Edge,
            from: unquote(from_module),
            to: unquote(to_module)

          schema unquote(collection_name) do
            edge_fields()
          end
        end

      {:module, _, _, _} = Module.create(module_name, contents, Macro.Env.location(__ENV__))
    end

    module_name
  end

  defp common_parent_module(module1, module2) do
    parent1 = parent_module_list(module1)
    parent2 = parent_module_list(module2)

    common_ordered_list(parent1, parent2)
    |> Module.concat()
  end

  defp parent_module_list(%module{}), do: parent_module_list(module)

  defp parent_module_list(module) do
    Module.split(module)
    |> Enum.drop(-1)
  end

  defp common_ordered_list(list1, list2, acc \\ [])

  defp common_ordered_list([h1 | t1], [h2 | t2], acc) when h1 == h2,
    do: common_ordered_list(t1, t2, [h1 | acc])

  defp common_ordered_list(_, _, acc), do: Enum.reverse(acc)

  defp gen_edge_collection_name(mod1, mod2) do
    name1 = last_mod(mod1)
    name2 = last_mod(mod2)

    sorted_elements = Enum.sort([name1, name2])

    name1 = List.first(sorted_elements) |> String.downcase()
    name2 = List.last(sorted_elements) |> String.downcase()

    "#{name1}_#{name2}"
  end

  defp last_mod(module) do
    module
    |> Module.split()
    |> List.last()
  end

  defp source_name(%{} = struct) do
    Map.get(struct.__meta__, :source)
  end

  defp source_name(id) when is_binary(id) do
    String.split(id, "/", trim: true)
    |> List.first()
  end

  defp source_name(module) do
    module.__schema__(:source)
  end

  defp struct_id(%{id: id} = struct) when is_struct(struct) do
    source = source_name(struct)

    "#{source}/#{id}"
  end

  defp struct_id(id) when is_binary(id) do
    case String.match?(id, ~r/[a-zA-Z0-9]+\/[a-zA-Z0-9]+/) do
      true -> id
      false -> raise ArgumentError, "Invalid format for ArangoDB document ID"
    end
  end

  defp struct_id(_), do: raise(ArgumentError, "Invalid struct or _id")

  defp validate_ecto_schema(module) do
    case Keyword.has_key?(module.__info__(:functions), :__schema__) do
      true -> module
      false -> raise "#{module} is not an Ecto Schema"
    end
  end

  defp validate_edge_module(module) do
    fields = module.__schema__(:fields)

    [:_from, :_to]
    |> Enum.all?(&Enum.member?(fields, &1))
    |> case do
      true -> module
      false -> raise "#{module} is not an Edge"
    end
  end

  defp edge_changeset(module, id1, id2, opts) do
    attrs =
      Keyword.get(opts, :fields, %{})
      |> Map.merge(%{_from: id1, _to: id2})

    struct = struct(module)

    try do
      Kernel.apply(module, :changeset, [struct, attrs])
    rescue
      UndefinedFunctionError ->
        Edge.edges_changeset(struct, attrs)
    end
  end

  defp maybe_create_edges_collection(struct, repo) do
    collection_name = source_name(struct)

    collection_exists?(repo, collection_name, 3)
    |> case do
      true ->
        struct

      false ->
        create_edges_collection(repo, collection_name)

        struct
    end
  end

  defp create_edges_collection(repo, collection_name) do
    conn = gen_conn_from_repo(repo)

    Arangox.post!(conn, "/_api/collection", %{name: collection_name, type: 3})
  end

  defp process_vars(query, vars) when is_list(vars),
    do: Enum.reduce(vars, {query, []}, &process_vars(&2, &1))

  defp process_vars({query, vars}, {key, %Ecto.Query{} = res}) do
    val = ArangoXEcto.Query.all(res)

    {String.replace(query, "@" <> Atom.to_string(key), val), vars}
  end

  defp process_vars({query, vars}, {_key, _val} = res),
    do: {query, [res | vars]}

  defp patch_map(map) do
    for {k, v} <- map, into: %{}, do: {String.to_atom(k), v}
  end

  defp filter_keys_for_struct(map) do
    key = Map.get(map, :_key)

    Map.put(map, :id, key)
    |> Map.drop([:_id, :_rev, :_key])
  end

  defp collection_type_to_integer(:document), do: 2

  defp collection_type_to_integer(:edge), do: 3

  defp collection_type_to_integer(type) when is_integer(type) and type in [2, 3], do: type

  defp collection_type_to_integer(_), do: 2
end
