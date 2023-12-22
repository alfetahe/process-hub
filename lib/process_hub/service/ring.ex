defmodule ProcessHub.Service.Ring do
  @moduledoc """
  The Ring service provides API functions for managing the hash ring.
  """

  alias ProcessHub.Service.LocalStorage
  alias :hash_ring, as: HashRing
  alias :hash_ring_node, as: HashRingNode

  @hash_ring :hash_ring_storage

  # TODO: add tests and documentation
  def storage_key() do
    @hash_ring
  end

  # TODO: add tests and documentation
  def create_ring(hub_nodes) do
    HashRing.make(hub_nodes)
  end

  @doc """
  Returns the hash ring instance belonging to the given `hub_id`.
  """
  @spec get_ring(ProcessHub.hub_id()) :: HashRing.t()
  def get_ring(hub_id) do
    LocalStorage.get(hub_id, @hash_ring)
  end

  @doc """
  Adds a new node to the passed-in `hash_ring` and returns the new hash ring.
  """
  @spec add_node(HashRing.t(), node()) :: HashRing.t()
  def add_node(hash_ring, node) do
    HashRingNode.make(node)
    |> HashRing.add_node(hash_ring)
  end

  @doc """
  Removes a node from the hash ring and returns the new hash ring.
  """
  @spec remove_node(HashRing.t(), node()) :: HashRing.t()
  def remove_node(hash_ring, node) do
    HashRing.remove_node(node, hash_ring)
  end

  @doc """
  Determines which nodes the given `child_id` belongs to.

  The `replication_factor` determines how many nodes to return.
  """
  @spec key_to_nodes(HashRing.t(), ProcessHub.child_id(), non_neg_integer()) :: [node()]
  def key_to_nodes(hash_ring, key, replication_factor) do
    HashRing.collect_nodes(key, replication_factor, hash_ring)
    |> Enum.map(fn {_, node, _, _} -> node end)
  end

  @doc """
  Determines which node the given `child_id` belongs to.
  """
  @spec key_to_node(HashRing.t(), ProcessHub.child_id(), non_neg_integer()) :: node()
  def key_to_node(hash_ring, key, replication_factor) do
    {_, node, _, _} = HashRing.collect_nodes(key, replication_factor, hash_ring) |> List.first()

    node
  end

  @doc """
  Returns a list of all nodes in the hash ring.
  """
  @spec key_to_node(HashRing.t(), ProcessHub.child_id(), non_neg_integer()) :: [node()]
  def nodes(hash_ring) do
    HashRing.get_node_list(hash_ring) |> Enum.map(fn {_, node, _, _} -> node end)
  end
end
