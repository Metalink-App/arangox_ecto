defmodule ArangoXEcto.Behaviour.Schema do
  @moduledoc false

  @behaviour Ecto.Adapter.Schema

  require Logger

  @doc """
  Called to autogenerate a value for id/embed_id/binary_id.

  Returns nil since we want to use an id generated by arangodb
  """
  @impl true
  def autogenerate(:id), do: raise("ArangoDB does not support type :id")
  def autogenerate(:embed_id), do: Ecto.UUID.generate()
  def autogenerate(:binary_id), do: nil

  @doc """
  Inserts a single new struct in the data store.
  """
  @impl true
  def insert(
        %{pid: conn, repo: repo},
        %{source: collection, schema: schema},
        fields,
        _on_conflict,
        returning,
        options
      ) do
    return_new = should_return_new?(returning, options)
    options = if return_new, do: "?returnNew=true", else: ""

    insert_fields =
      fields
      |> process_fields(schema)

    doc = Enum.into(insert_fields, %{})

    Logger.debug("#{inspect(__MODULE__)}.insert", %{
      "#{inspect(__MODULE__)}.insert-params" => %{document: inspect(doc)}
    })

    maybe_create_collection(repo, schema, conn)

    Arangox.post(
      conn,
      "/_api/document/#{collection}" <> options,
      doc
    )
    |> extract_doc(return_new)
    #    |> ArangoXEcto.Behaviour.Relationship.process_relationships()
    |> single_doc_result(returning)
  end

  @doc """
  Inserts multiple entries into the data store.
  """
  @impl true
  def insert_all(
        %{pid: conn, repo: repo},
        %{source: collection, schema: schema},
        _header,
        list,
        _on_conflict,
        returning,
        _placeholders,
        options
      ) do
    docs = build_docs(list)
    return_new = should_return_new?(returning, options)
    options = if return_new, do: "?returnNew=true", else: ""

    Logger.debug("#{inspect(__MODULE__)}.insert_all", %{
      "#{inspect(__MODULE__)}.insert_all-params" => %{documents: inspect(docs)}
    })

    maybe_create_collection(repo, schema, conn)

    case Arangox.post(
           conn,
           "/_api/document/#{collection}" <> options,
           docs
         ) do
      {:ok, %{body: body}} ->
        get_insert_fields(body, returning, return_new)

      {:error, %{status: status}} ->
        {:invalid, status}
    end
  end

  defp process_fields(fields, schema) do
    process_fields(ArangoXEcto.schema_type!(schema), schema, fields)
  end

  defp process_fields(:edge, schema, fields) when is_list(fields) do
    {from, to} = get_edge_associations(schema)

    foreign_keys =
      get_foreign_keys(schema)
      |> Enum.reject(&(&1 in [:_from, :_to]))

    fields
    |> Keyword.drop(foreign_keys)
    |> Keyword.update!(:_from, &key_to_id(&1, from))
    |> Keyword.update!(:_to, &key_to_id(&1, to))
  end

  defp process_fields(:document, _schema, fields), do: fields

  defp get_edge_associations(schema) do
    Enum.reduce(schema.__schema__(:associations), {nil, nil}, fn assoc_key, acc ->
      assoc = schema.__schema__(:association, assoc_key)

      case assoc.owner_key do
        :_from -> {assoc.queryable, elem(acc, 1)}
        :_to -> {elem(acc, 0), assoc.queryable}
        _ -> acc
      end
    end)
  end

  @doc """
  Deletes a single struct with the given filters.
  """
  @impl true
  def delete(%{pid: conn}, %{source: collection}, [{:_key, key}], _options) do
    Logger.debug("#{inspect(__MODULE__)}.delete", %{
      "#{inspect(__MODULE__)}.delete-params" => %{collection: collection, key: key}
    })

    case Arangox.delete(conn, "/_api/document/#{collection}/#{key}") do
      {:ok, _} -> {:ok, []}
      {:error, %{status: 404}} -> {:error, :stale}
      {:error, %{status: status}} -> {:error, status}
    end
  end

  def delete(_adapter_meta, _schema_meta, _filters, _options) do
    # TODO: Do this
    raise "Deleting with filters other than _key is not supported yet"
  end

  @doc """
  Updates a single struct with the given filters.
  """
  @impl true
  def update(
        %{pid: conn, repo: repo},
        %{source: collection, schema: schema},
        fields,
        [{:_key, key}],
        returning,
        options
      ) do
    document = Enum.into(fields, %{})

    return_new = should_return_new?(returning, options)
    options = if return_new, do: "?returnNew=true", else: ""

    Logger.debug("#{inspect(__MODULE__)}.update", %{
      "#{inspect(__MODULE__)}.update-params" => %{document: inspect(document)}
    })

    maybe_create_collection(repo, schema, conn)

    Arangox.patch(
      conn,
      "/_api/document/#{collection}/#{key}" <> options,
      document
    )
    |> extract_doc(return_new)
    |> single_doc_result(returning)
  end

  def update(_adapter_meta, _schema_meta, _fields, _filters, _returning, _options) do
    # TODO: Do this
    raise "Updating with filters other than _key is not supported yet"
  end

  @doc """
  Gets the foreign keys from a schema
  """
  @spec get_foreign_keys(nil | module()) :: [atom()]
  def get_foreign_keys(nil), do: []

  def get_foreign_keys(schema) do
    Enum.map(schema.__schema__(:associations), fn assoc ->
      schema.__schema__(:association, assoc)
    end)
    |> Enum.filter(fn
      %Ecto.Association.BelongsTo{} -> true
      _ -> false
    end)
    |> Enum.map(&Map.get(&1, :owner_key))
  end

  defp should_return_new?(returning, options) do
    Keyword.get(options, :return_new, false) or
      Enum.any?(returning, &(&1 not in [:_id, :_key, :_rev]))
  end

  defp extract_doc({:ok, %Arangox.Response{body: %{"new" => doc}}}, true) do
    {:ok, doc}
  end

  defp extract_doc({:ok, %Arangox.Response{body: doc}}, false) do
    {:ok, patch_body_keys(doc)}
  end

  defp extract_doc({:error, %{error_num: 1210, message: msg}}, _) do
    {:invalid, [unique: msg]}
  end

  defp extract_doc({:error, %{error_num: error_num, message: msg}}, _) do
    raise "#{inspect(__MODULE__)} Error(#{error_num}): #{msg}"
  end

  defp single_doc_result({:ok, doc}, returning) do
    {:ok, Enum.map(returning, &{&1, Map.get(doc, Atom.to_string(&1))})}
  end

  defp single_doc_result({:error, _} = res, _), do: res

  defp single_doc_result({:invalid, _} = res, _), do: res

  defp maybe_create_collection(repo, schema, conn) when is_atom(repo) do
    type = ArangoXEcto.schema_type!(schema) |> collection_type_to_integer()
    collection_name = schema.__schema__(:source)
    is_static = Keyword.get(repo.config(), :static, false)

    unless ArangoXEcto.collection_exists?(conn, collection_name, type) do
      if is_static do
        raise("Collection (#{collection_name}) does not exist. Maybe a migration is missing.")
      else
        create_collection(conn, collection_name, type)
      end
    end
  end

  defp create_collection(conn, collection_name, type) do
    Arangox.post!(conn, "/_api/collection", %{name: collection_name, type: type})
  end

  defp build_docs(fields) when is_list(fields) do
    Enum.map(
      fields,
      fn
        %{} = doc -> doc
        doc when is_list(doc) -> Enum.into(doc, %{})
      end
    )
  end

  defp patch_body_keys(%{} = body) do
    for {k, v} <- body, into: %{}, do: {replacement_key(k), v}
  end

  defp get_insert_fields(docs, returning, false), do: process_docs(docs, returning)

  defp get_insert_fields(docs, returning, true) do
    process_docs(Enum.map(docs, & &1["new"]), returning)
  end

  @replacements %{"1" => "_key", "2" => "_rev", "3" => "_id"}
  defp replacement_key(key) do
    case Map.get(@replacements, to_string(key)) do
      nil -> key
      k -> k
    end
  end

  defp process_docs(docs, []), do: {length(docs), nil}

  defp process_docs(docs, returning) do
    new_docs =
      Enum.map(docs, fn doc ->
        Enum.map(returning, &Map.get(doc, Atom.to_string(&1)))
      end)

    {length(docs), new_docs}
  end

  defp collection_type_to_integer(:document), do: 2

  defp collection_type_to_integer(:edge), do: 3

  defp collection_type_to_integer(_), do: 2

  defp key_to_id(key, module) when is_binary(key) do
    case String.match?(key, ~r/[a-zA-Z0-9]+\/[a-zA-Z0-9]+/) do
      true -> key
      false -> module.__schema__(:source) <> "/" <> key
    end
  end
end
