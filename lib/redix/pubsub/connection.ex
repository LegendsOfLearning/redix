defmodule Redix.PubSub.Connection do
  @moduledoc false

  @behaviour :gen_statem

  alias Redix.{ConnectionError, Connector, Protocol}

  require Logger

  defstruct [
    :opts,
    :transport,
    :socket,
    :continuation,
    :backoff_current,
    :last_disconnect_reason,
    :connected_address,
    subscriptions: %{},
    pending_subscriptions: %{},
    monitors: %{}
  ]

  @backoff_exponent 1.5

  @impl true
  def callback_mode(), do: :state_functions

  @impl true
  def init(opts) do
    transport = if(opts[:ssl], do: :ssl, else: :gen_tcp)
    data = %__MODULE__{opts: opts, transport: transport}

    if opts[:sync_connect] do
      with {:ok, socket, address} <- Connector.connect(data.opts),
           :ok <- setopts(data, socket, active: :once) do
        data = %__MODULE__{
          data
          | socket: socket,
            last_disconnect_reason: nil,
            backoff_current: nil,
            connected_address: address
        }

        {:ok, :connected, data}
      else
        {:error, reason} -> {:stop, reason}
        {:stop, reason} -> {:stop, reason}
      end
    else
      send(self(), :handle_possible_erlang_bug)
      {:ok, :state_needed_because_of_possible_erlang_bug, data}
    end
  end

  ## States

  # If I use the action {:next_event, :internal, :connect} when returning
  # {:ok, :disconnected, data} from init/1, then Erlang 20 (not 21) blows up saying:
  # {:bad_return_from_init, {:next_events, :internal, :connect}}. The weird thing is
  # that if I use `{:next_even, :internal, :connect}` it complains but with `:next_even`,
  # but with `:next_event` it seems to add the final "s" (`:next_events`). No idea
  # what's going on and no time to fix it.
  def state_needed_because_of_possible_erlang_bug(:info, :handle_possible_erlang_bug, data) do
    {:next_state, :disconnected, data, {:next_event, :internal, :connect}}
  end

  def state_needed_because_of_possible_erlang_bug(_event, _info, _data) do
    {:keep_state_and_data, :postpone}
  end

  def disconnected(:internal, :handle_disconnection, data) do
    log(data, :disconnection, fn ->
      "Disconnected from Redis (#{data.connected_address}): " <>
        Exception.message(data.last_disconnect_reason)
    end)

    if data.opts[:exit_on_disconnection] do
      {:stop, data.last_disconnect_reason}
    else
      Enum.each(data.monitors, fn {pid, ref} ->
        send(pid, ref, :disconnected, %{error: data.last_disconnect_reason})
      end)

      data = %{
        data
        | subscriptions: %{},
          pending_subscriptions: data.subscriptions,
          connected_address: nil
      }

      {:keep_state, data}
    end
  end

  def disconnected({:timeout, :reconnect}, nil, _data) do
    {:keep_state_and_data, {:next_event, :internal, :connect}}
  end

  def disconnected(:internal, :connect, data) do
    with {:ok, socket, address} <- Connector.connect(data.opts),
         :ok <- setopts(data, socket, active: :once) do
      if data.last_disconnect_reason do
        log(data, :reconnection, fn -> "Reconnected to Redis (#{address})" end)
      end

      data = %__MODULE__{
        data
        | socket: socket,
          last_disconnect_reason: nil,
          backoff_current: nil,
          connected_address: address
      }

      {:next_state, :connected, data, {:next_event, :internal, :handle_connection}}
    else
      {:error, reason} ->
        log(data, :failed_connection, fn ->
          "Failed to connect to Redis (#{format_address(data)}): " <>
            Exception.message(%ConnectionError{reason: reason})
        end)

        disconnect(data, reason)

      {:stop, reason} ->
        {:stop, reason, data}
    end
  end

  def disconnected({:call, from}, {operation, targets, pid}, data)
      when operation in [:subscribe, :psubscribe] do
    {data, ref} = monitor_new(data, pid)
    :ok = :gen_statem.reply(from, {:ok, ref})

    # We can just add subscribers to channels here since when we'll reconnect, the connection
    # will have to reconnect to all the channels/patterns anyways.
    {_targets_to_subscribe_to, _already_subscribed_targets, data} =
      subscribe_pid_to_targets(data, operation, targets, pid)

    send(pid, ref, :disconnected, %{reason: data.last_disconnect_reason})

    {:keep_state, data}
  end

  def disconnected({:call, from}, {operation, targets, pid}, data)
      when operation in [:unsubscribe, :punsubscribe] do
    :ok = :gen_statem.reply(from, :ok)

    case data.monitors[pid] do
      ref when is_reference(ref) ->
        {_targets_to_unsubscribe_from, data} =
          unsubscribe_pid_from_targets(data, operation, targets, pid)

        {kind, target_type} =
          case operation do
            :unsubscribe -> {:unsubscribed, :channel}
            :punsubscribe -> {:punsubscribed, :pattern}
          end

        Enum.each(targets, fn target ->
          send(pid, ref, kind, %{target_type => target})
        end)

        data = demonitor_if_not_subscribed_to_anything(data, pid)
        {:keep_state, data}

      nil ->
        :keep_state_and_data
    end
  end

  def connected(:internal, :handle_connection, data) do
    # We clean up channels/patterns that don't have any subscribers. We do this because some
    # subscribers could have unsubscribed from a channel/pattern while disconnected.
    data =
      update_in(data.subscriptions, fn subscriptions ->
        :maps.filter(fn _target, subscribers -> MapSet.size(subscribers) > 0 end, subscriptions)
      end)

    channels_to_subscribe_to =
      for {{:channel, channel}, _subscribers} <- data.pending_subscriptions, do: channel

    patterns_to_subscribe_to =
      for {{:pattern, pattern}, _subscribers} <- data.pending_subscriptions, do: pattern

    case subscribe(data, channels_to_subscribe_to, patterns_to_subscribe_to) do
      :ok -> {:keep_state, data}
      {:error, reason} -> disconnect(data, reason)
    end
  end

  def connected({:call, from}, {operation, targets, pid}, data)
      when operation in [:subscribe, :psubscribe] do
    {data, ref} = monitor_new(data, pid)
    :ok = :gen_statem.reply(from, {:ok, ref})

    {targets_to_subscribe_to, already_subscribed_targets, data} =
      subscribe_pid_to_targets(data, operation, targets, pid)

    # We only send a "subscribed" message right away to the subscribers for targets that the
    # connection was already subscribed to.
    {kind, target_type} =
      case operation do
        :subscribe -> {:subscribed, :channel}
        :psubscribe -> {:psubscribed, :pattern}
      end

    Enum.each(already_subscribed_targets, fn target ->
      send(pid, ref, kind, %{target_type => target})
    end)

    case subscribe_with_operation(data, operation, targets_to_subscribe_to) do
      :ok -> {:keep_state, data}
      {:error, reason} -> disconnect(data, reason)
    end
  end

  def connected({:call, from}, {operation, targets, pid}, data)
      when operation in [:unsubscribe, :punsubscribe] do
    :ok = :gen_statem.reply(from, :ok)

    case data.monitors[pid] do
      ref when is_reference(ref) ->
        {targets_to_unsubscribe_from, data} =
          unsubscribe_pid_from_targets(data, operation, targets, pid)

        {kind, target_type} =
          case operation do
            :unsubscribe -> {:unsubscribed, :channel}
            :punsubscribe -> {:punsubscribed, :pattern}
          end

        Enum.each(targets, fn target ->
          send(pid, ref, kind, %{target_type => target})
        end)

        data = demonitor_if_not_subscribed_to_anything(data, pid)

        {channels_to_unsubscribe_from, patterns_to_unsubscribe_from} =
          case operation do
            :unsubscribe -> {targets_to_unsubscribe_from, []}
            :punsubscribe -> {[], targets_to_unsubscribe_from}
          end

        case unsubscribe(data, channels_to_unsubscribe_from, patterns_to_unsubscribe_from) do
          :ok -> {:keep_state, data}
          {:error, reason} -> disconnect(data, reason)
        end

      nil ->
        :keep_state_and_data
    end
  end

  def connected(:info, {transport_closed, socket}, %__MODULE__{socket: socket} = data)
      when transport_closed in [:tcp_closed, :ssl_closed] do
    disconnect(data, transport_closed)
  end

  def connected(:info, {transport_error, socket, reason}, %__MODULE__{socket: socket} = data)
      when transport_error in [:tcp_error, :ssl_error] do
    disconnect(data, reason)
  end

  def connected(:info, {transport, socket, bytes}, %__MODULE__{socket: socket} = data)
      when transport in [:tcp, :ssl] do
    :ok = setopts(data, socket, active: :once)

    case new_bytes(data, bytes) do
      {:ok, data} -> {:keep_state, data}
      {:error, reason} -> disconnect(data, reason)
    end
  end

  def connected(:info, {:DOWN, ref, :process, pid, _reason}, data) do
    {^ref, data} = pop_in(data.monitors[pid])

    {targets_to_unsubscribe_from, data} =
      get_and_update_in(data.subscriptions, fn subscriptions ->
        Enum.flat_map_reduce(subscriptions, subscriptions, fn {target, subscribers}, acc ->
          new_subscribers = MapSet.delete(subscribers, pid)

          if MapSet.size(new_subscribers) == 0 do
            {[target], Map.put(acc, target, new_subscribers)}
          else
            {[], Map.put(acc, target, new_subscribers)}
          end
        end)
      end)

    channels_to_unsubscribe_from =
      for {:channel, channel} <- targets_to_unsubscribe_from, do: channel

    patterns_to_unsubscribe_from =
      for {:pattern, pattern} <- targets_to_unsubscribe_from, do: pattern

    case unsubscribe(data, channels_to_unsubscribe_from, patterns_to_unsubscribe_from) do
      :ok -> {:keep_state, data}
      {:error, reason} -> disconnect(data, reason)
    end
  end

  ## Helpers

  defp new_bytes(data, "") do
    {:ok, data}
  end

  defp new_bytes(data, bytes) do
    case (data.continuation || (&Protocol.parse/1)).(bytes) do
      {:ok, resp, rest} ->
        with {:ok, data} <- handle_pubsub_msg(data, resp),
             do: new_bytes(%{data | continuation: nil}, rest)

      {:continuation, continuation} ->
        {:ok, %{data | continuation: continuation}}
    end
  end

  defp handle_pubsub_msg(data, [operation, target, _subscribers_count])
       when operation in ["subscribe", "psubscribe"] do
    operation = String.to_existing_atom(operation)

    target_key = key_for_target(operation, target)

    {kind, target_type} =
      case operation do
        :subscribe -> {:subscribed, :channel}
        :psubscribe -> {:psubscribed, :pattern}
      end

    case pop_in(data.pending_subscriptions[target_key]) do
      # We did not have any pending subscribers for this target. This can happen if subscribers
      # unsubscribe before their subscription is moved out of the pending subscriptions.
      {nil, data} ->
        {:ok, data}

      # We had pending subscribers, so we just move them to subscribers and notify them they're
      # subscribed now.
      {pending_subscribers, data} ->
        Enum.each(pending_subscribers, fn pid ->
          ref = Map.fetch!(data.monitors, pid)
          send(pid, ref, kind, %{target_type => target})
        end)

        {:ok, put_in(data.subscriptions[target_key], pending_subscribers)}
    end
  end

  defp handle_pubsub_msg(data, [operation, target, _subscribers_count])
       when operation in ["unsubscribe", "punsubscribe"] do
    operation = String.to_existing_atom(operation)

    target_key = key_for_target(operation, target)

    case data.subscriptions do
      # If an unsubscription confirmation arrives from Redis but we have subscribers for that
      # target, we move the subscribers to pending_subscriptions and then subscribe again
      # to Redis.
      %{^target_key => subscribers} ->
        data = update_in(data.subscriptions, &Map.delete(&1, target_key))
        data = put_in(data.pending_subscriptions[target_key], subscribers)

        if MapSet.size(subscribers) != 0 do
          subscribe_operation =
            case operation do
              :unsubscribe -> :subscribe
              :punsubscribe -> :psubscribe
            end

          with :ok <- subscribe_with_operation(data, subscribe_operation, [target]) do
            {:ok, data}
          end
        else
          {:ok, data}
        end

      _other ->
        {:ok, data}
    end
  end

  defp handle_pubsub_msg(data, ["message", channel, payload]) do
    subscribers = Map.get(data.subscriptions, {:channel, channel}, [])
    properties = %{channel: channel, payload: payload}

    Enum.each(subscribers, fn pid ->
      ref = Map.fetch!(data.monitors, pid)
      send(pid, ref, :message, properties)
    end)

    {:ok, data}
  end

  defp handle_pubsub_msg(data, ["pmessage", pattern, channel, payload]) do
    subscribers = Map.get(data.subscriptions, {:pattern, pattern}, [])
    properties = %{channel: channel, pattern: pattern, payload: payload}

    Enum.each(subscribers, fn pid ->
      ref = Map.fetch!(data.monitors, pid)
      send(pid, ref, :pmessage, properties)
    end)

    {:ok, data}
  end

  # Returns {targets_to_subscribe_to, already_subscribed_targets, data}.
  defp subscribe_pid_to_targets(data, operation, targets, pid) do
    initial_acc =
      {data.subscriptions, data.pending_subscriptions, _to_sub = [], _already_subbed = []}

    {subs, pending_subs, to_sub, already_subbed} =
      Enum.reduce(targets, initial_acc, fn target, {subs, pending_subs, to_sub, already_subbed} ->
        target_key = key_for_target(operation, target)

        case {subs, pending_subs} do
          {subs, %{^target_key => subscribers}} ->
            pending_subs = %{pending_subs | target_key => MapSet.put(subscribers, pid)}
            {subs, pending_subs, to_sub, already_subbed}

          {%{^target_key => subscribers}, pending_subs} ->
            subs = %{subs | target_key => MapSet.put(subscribers, pid)}
            {subs, pending_subs, to_sub, [target | already_subbed]}

          {_subs, _pending_subs} ->
            pending_subs = Map.put(pending_subs, target_key, MapSet.new([pid]))
            {subs, pending_subs, [target | to_sub], already_subbed}
        end
      end)

    data = %{data | subscriptions: subs, pending_subscriptions: pending_subs}
    {to_sub, already_subbed, data}
  end

  # Returns {targets_to_unsubscribe_from, data}.
  defp unsubscribe_pid_from_targets(data, operation, targets, pid) do
    initial_acc = {data.subscriptions, data.pending_subscriptions, _to_unsub = []}

    {subs, pending_subs, to_unsub} =
      Enum.reduce(targets, initial_acc, fn target, {subs, pending_subs, to_unsub} ->
        target_key = key_for_target(operation, target)

        case {subs, pending_subs} do
          {%{^target_key => subscribers}, pending_subs} ->
            subscribers = MapSet.delete(subscribers, pid)

            if MapSet.size(subscribers) == 0 do
              subs = Map.delete(subs, target_key)
              {subs, pending_subs, [target | to_unsub]}
            else
              subs = %{subs | target_key => subscribers}
              {subs, pending_subs, to_unsub}
            end

          {subs, %{^target_key => subscribers}} ->
            subscribers = MapSet.delete(subscribers, pid)

            if MapSet.size(subscribers) == 0 do
              pending_subs = Map.delete(pending_subs, target_key)
              {subs, pending_subs, [target | to_unsub]}
            else
              pending_subs = %{pending_subs | target_key => subscribers}
              {subs, pending_subs, to_unsub}
            end
        end
      end)

    data = %{data | subscriptions: subs, pending_subscriptions: pending_subs}
    {to_unsub, data}
  end

  defp subscribe_with_operation(data, :subscribe, targets),
    do: subscribe(data, _channels = targets, _patterns = [])

  defp subscribe_with_operation(data, :psubscribe, targets),
    do: subscribe(data, _channels = [], _patterns = targets)

  defp subscribe(_data, [], []) do
    :ok
  end

  defp subscribe(data, channels, patterns) do
    pipeline =
      case {channels, patterns} do
        {channels, []} -> [["SUBSCRIBE" | channels]]
        {[], patterns} -> [["PSUBSCRIBE" | patterns]]
        {channels, patterns} -> [["SUBSCRIBE" | channels], ["PSUBSCRIBE" | patterns]]
      end

    transport_send(data, Enum.map(pipeline, &Protocol.pack/1))
  end

  defp unsubscribe(_data, [], []) do
    :ok
  end

  defp unsubscribe(data, channels, patterns) do
    pipeline =
      case {channels, patterns} do
        {channels, []} -> [["UNSUBSCRIBE" | channels]]
        {[], patterns} -> [["PUNSUBSCRIBE" | patterns]]
        {channels, patterns} -> [["UNSUBSCRIBE" | channels], ["PUNSUBSCRIBE" | patterns]]
      end

    transport_send(data, Enum.map(pipeline, &Protocol.pack/1))
  end

  defp transport_send(data, bytes) do
    case data.transport.send(data.socket, bytes) do
      :ok ->
        :ok

      {:error, reason} ->
        :ok = :gen_tcp.close(data.socket)
        {:error, reason}
    end
  end

  defp monitor_new(data, pid) do
    case data.monitors do
      %{^pid => ref} ->
        {data, ref}

      _ ->
        ref = Process.monitor(pid)
        data = put_in(data.monitors[pid], ref)
        {data, ref}
    end
  end

  defp demonitor_if_not_subscribed_to_anything(data, pid) do
    still_subscribed_to_something? =
      Enum.any?(data.subscriptions, fn {_target, subscribers} -> pid in subscribers end)

    if still_subscribed_to_something? do
      data
    else
      {monitor_ref, data} = pop_in(data.monitors[pid])
      Process.demonitor(monitor_ref, [:flush])
      data
    end
  end

  defp key_for_target(:subscribe, channel), do: {:channel, channel}
  defp key_for_target(:unsubscribe, channel), do: {:channel, channel}
  defp key_for_target(:psubscribe, pattern), do: {:pattern, pattern}
  defp key_for_target(:punsubscribe, pattern), do: {:pattern, pattern}

  defp setopts(data, socket, opts) do
    inets_mod(data.transport).setopts(socket, opts)
  end

  defp inets_mod(:gen_tcp), do: :inet
  defp inets_mod(:ssl), do: :ssl

  defp next_backoff(data) do
    backoff_current = data.backoff_current || data.opts[:backoff_initial]
    backoff_max = data.opts[:backoff_max]
    next_backoff = round(backoff_current * @backoff_exponent)

    backoff_current =
      if backoff_max == :infinity do
        next_backoff
      else
        min(next_backoff, backoff_max)
      end

    {backoff_current, put_in(data.backoff_current, backoff_current)}
  end

  def disconnect(data, reason) do
    {next_backoff, data} = next_backoff(data)
    data = put_in(data.last_disconnect_reason, %ConnectionError{reason: reason})
    timeout_action = {{:timeout, :reconnect}, next_backoff, nil}
    actions = [{:next_event, :internal, :handle_disconnection}, timeout_action]
    {:next_state, :disconnected, data, actions}
  end

  defp send(pid, ref, kind, properties)
       when is_pid(pid) and is_reference(ref) and is_atom(kind) and is_map(properties) do
    send(pid, {:redix_pubsub, self(), ref, kind, properties})
  end

  defp log(data, action, message) do
    level =
      data.opts
      |> Keyword.fetch!(:log)
      |> Keyword.fetch!(action)

    Logger.log(level, message)
  end

  defp format_address(%{opts: opts} = _state) do
    if opts[:sentinel] do
      "sentinel"
    else
      "#{opts[:host]}:#{opts[:port]}"
    end
  end
end
