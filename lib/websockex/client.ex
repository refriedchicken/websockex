defmodule WebSockex.Client do
  @handshake_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  @moduledoc ~S"""
  A client handles negotiating the connection, then sending frames, receiving
  frames, closing, and reconnecting that connection.

  A simple client implementation would be:

  ```
  defmodule WsClient do
    use WebSockex.Client

    def start_link(state) do
      WebSockex.Client.start_link(__MODULE__, state)
    end

    def handle_frame({:text, msg}, state) do
      IO.puts "Received a message: #{msg}"
      {:ok, state}
    end
  end
  ```
  """

  @type frame :: {:ping | :ping, nil | binary} | {:text | :binary, binary}
  @type close_frame :: {integer, binary}

  @type options :: [option]

  @type option :: {:extra_headers, [WebSockex.Conn.header]}

  @typedoc """
  The reason given and sent to the server when locally closing a connection.

  A `:normal` reason is the same as a `1000` reason.
  """
  @type close_reason :: {:remote | :local, :normal} | {:remote | :local, :normal | integer, close_frame} | {:error, term}

  @doc """
  Invoked after connection is established.
  """
  @callback init(args :: any, WebSockex.Conn.t) :: {:ok, state :: term}

  @doc """
  Invoked on the reception of a frame on the socket.

  The control frames have possible payloads, when they don't have a payload
  then the frame will have `nil` as the payload. e.g. `{:ping, nil}`
  """
  @callback handle_frame(frame, state :: term) ::
    {:ok, new_state}
    | {:reply, frame, new_state}
    | {:close, new_state}
    | {:close, close_frame, new_state} when new_state: term

  @doc """
  Invoked to handle asynchronous `cast/2` messages.
  """
  @callback handle_cast(msg :: term, state ::term) ::
    {:ok, new_state}
    | {:reply, frame, new_state}
    | {:close, new_state}
    | {:close, close_frame, new_state} when new_state: term

  @doc """
  Invoked to handle all other non-WebSocket messages.
  """
  @callback handle_info(msg :: term, state :: term) ::
    {:ok, new_state}
    | {:reply, frame, new_state}
    | {:close, new_state}
    | {:close, close_frame, new_state} when new_state: term

  @doc """
  Invoked when the WebSocket disconnects from the server.
  """
  @callback handle_disconnect(close_reason, state :: term) ::
    {:ok, state}
    | {:reconnect, state} when state: term

  @doc """
  Invoked when the Websocket receives a ping frame
  """
  @callback handle_ping(:ping | {:ping, binary}, state :: term) ::
    {:ok, new_state}
    | {:reply, frame, new_state}
    | {:close, new_state}
    | {:close, close_frame, new_state} when new_state: term

  @doc """
  Invoked when the Websocket receives a pong frame.
  """
  @callback handle_pong(:pong | {:pong, binary}, state :: term) ::
    {:ok, new_state}
    | {:reply, frame, new_state}
    | {:close, new_state}
    | {:close, close_frame, new_state} when new_state: term

  @doc """
  Invoked when the process is terminating.
  """
  @callback terminate(close_reason, state :: term) :: any

  @doc """
  Invoked when a new version the module is loaded during runtime.
  """
  @callback code_change(old_vsn :: term | {:down, term},
                        state :: term, extra :: term) ::
    {:ok, new_state :: term}
    | {:error, reason :: term}

  @optional_callbacks [handle_disconnect: 2, handle_ping: 2, handle_pong: 2, terminate: 2,
                       code_change: 3]

  defmacro __using__(_) do
    quote location: :keep do
      @behaviour WebSockex.Client

      @doc false
      def init(state, conn) do
        {:ok, state}
      end

      @doc false
      def handle_frame(frame, _state) do
        raise "No handle_frame/2 clause in #{__MODULE__} provided for #{inspect frame}"
      end

      @doc false
      def handle_cast(frame, _state) do
        raise "No handle_cast/2 clause in #{__MODULE__} provided for #{inspect frame}"
      end

      @doc false
      def handle_info(frame, state) do
        require Logger
        Logger.error "No handle_info/2 clause in #{__MODULE__} provided for #{inspect frame}"
        {:ok, state}
      end

      @doc false
      def handle_disconnect(_close_reason, state) do
        {:ok, state}
      end

      @doc false
      def handle_ping(:ping, state) do
        {:reply, :pong, state}
      end
      def handle_ping({:ping, msg}, state) do
        {:reply, {:pong, msg}, state}
      end

      @doc false
      def handle_pong(:pong, state), do: {:ok, state}
      def handle_pong({:pong, _}, state), do: {:ok, state}

      @doc false
      def terminate(_close_reason, _state), do: :ok

      @doc false
      def code_change(_old_vsn, state, _extra), do: {:ok, state}

      defoverridable [init: 2, handle_frame: 2, handle_cast: 2, handle_info: 2, handle_ping: 2,
                      handle_pong: 2, handle_disconnect: 2, terminate: 2, code_change: 3]
    end
  end

  @doc """
  Starts a `WebSockex.Client` process linked to the current process.

  ### Options

  - `:extra_headers` - defines other headers to be send in the opening request.
  - `:cacerts` - The CA certifications for use in an secure connection. These
  certifications need a list of decoded binaries. See the [Erlang `:public_key`
  module][public_key] for more information.

  [public_key]: http://erlang.org/doc/apps/public_key/using_public_key.html
  """
  @spec start_link(String.t, module, term, options) :: {:ok, pid} | {:error, term}
  def start_link(url, module, state, opts \\ []) do
    case URI.parse(url) do
      # This is confusing to look at. But it's just a match with multiple guards
      %URI{host: host, port: port, scheme: protocol}
      when is_nil(host)
      when is_nil(port)
      when not protocol in ["ws", "wss"] ->
        {:error, %WebSockex.URLError{url: url}}
      %URI{} = uri ->
        :proc_lib.start_link(__MODULE__, :init, [self(), uri, module, state, opts])
      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Asynchronously sends a message to a client that is handled by `c:handle_cast/2`.
  """
  @spec cast(pid, term) :: :ok
  def cast(client, message) do
    send(client, {:"$websockex_cast", message})
    :ok
  end

  @doc """
  Queue a frame to be sent asynchronously.
  """
  @spec send_frame(pid, frame) :: :ok | {:error, WebSockex.FrameEncodeError.t}
  def send_frame(pid, frame) do
    with {:ok, binary_frame} <- WebSockex.Frame.encode_frame(frame),
    do: send(pid, {:"$websockex_send", binary_frame})
  end

  @doc false
  @spec init(pid, URI.t, module, term, options) :: {:ok, pid} | {:error, term}
  def init(parent, uri, module, module_state, opts) do
    # OTP stuffs
    debug = :sys.debug_options([])

    with conn <- WebSockex.Conn.new(uri, opts),
         {:ok, conn} <- open_connection(conn),
         {:ok, new_module_state} <- module_init(module, module_state, conn) do
           :proc_lib.init_ack(parent, {:ok, self()})
            websocket_loop(parent, debug, %{conn: conn,
                                            module: module,
                                            module_state: new_module_state,
                                            buffer: <<>>,
                                            fragment: nil})
    else
      {:error, reason} ->
        error = Exception.normalize(:error, reason)
        :proc_lib.init_ack(parent, error)
        exit(error)
    end
  rescue
    exception ->
      exit({exception, System.stacktrace})
  end

  ## OTP Stuffs

  def system_continue(parent, debug, state) do
    websocket_loop(parent, debug, state)
  end

  def system_terminate(reason, parent, debug, state) do
    terminate(reason, parent, debug, state)
  end

  def system_get_state(state) do
    {:ok, state, state}
  end

  def system_replace_state(fun, state) do
    new_state = fun.(state)
    {:ok, new_state, new_state}
  end

  # Internals! Yay

  defp open_connection(conn) do
    with {:ok, conn} <- WebSockex.Conn.open_socket(conn),
         key <- :crypto.strong_rand_bytes(16) |> Base.encode64,
         {:ok, request} <- WebSockex.Conn.build_request(conn, key),
         :ok <- WebSockex.Conn.socket_send(conn, request),
         {:ok, headers} <- WebSockex.Conn.handle_response(conn),
         :ok <- validate_handshake(headers, key),
         :ok <- WebSockex.Conn.set_active(conn),
    do: {:ok, conn}
  end

  defp validate_handshake(headers, key) do
    challenge = :crypto.hash(:sha, key <> @handshake_guid) |> Base.encode64

    {_, res} = List.keyfind(headers, "Sec-Websocket-Accept", 0)

    if challenge == res do
      :ok
    else
      {:error, %WebSockex.HandshakeError{response: res, challenge: challenge}}
    end
  end

  defp websocket_loop(parent, debug, state) do
    case WebSockex.Frame.parse_frame(state.buffer) do
      {:ok, frame, buffer} ->
        handle_frame(frame, parent, debug, %{state | buffer: buffer})
      :incomplete ->
        transport = state.conn.transport
        socket = state.conn.socket
        receive do
          {:system, from, req} ->
            :sys.handle_system_msg(req, from, parent, __MODULE__, debug, state)
          {:"$websockex_cast", msg} ->
            common_handle({:handle_cast, msg}, parent, debug, state)
          {:"$websockex_send", binary_frame} ->
            handle_send(binary_frame, parent, debug, state)
          {^transport, ^socket, message} ->
            buffer = <<state.buffer::bitstring, message::bitstring>>
            websocket_loop(parent, debug, %{state | buffer: buffer})
          msg ->
            common_handle({:handle_info, msg}, parent, debug, state)
        end
    end
  end

  defp handle_frame(:ping, parent, debug, state) do
    common_handle({:handle_ping, :ping}, parent, debug, state)
  end
  defp handle_frame({:ping, msg}, parent, debug, state) do
    common_handle({:handle_ping, {:ping, msg}}, parent, debug, state)
  end
  defp handle_frame(:pong, parent, debug, state) do
    common_handle({:handle_pong, :pong}, parent, debug, state)
  end
  defp handle_frame({:pong, msg}, parent, debug, state) do
    common_handle({:handle_pong, {:pong, msg}}, parent, debug, state)
  end
  defp handle_frame(:close, parent, debug, state) do
    handle_close({:remote, :normal}, parent, debug, state)
  end
  defp handle_frame({:close, code, reason}, parent, debug, state) do
    handle_close({:remote, code, reason}, parent, debug, state)
  end
  defp handle_frame({:fragment, _, _} = fragment, parent, debug, state) do
    handle_fragment(fragment, parent, debug, state)
  end
  defp handle_frame({:continuation, _} = fragment, parent, debug, state) do
    handle_fragment(fragment, parent, debug, state)
  end
  defp handle_frame({:finish, _} = fragment, parent, debug, state) do
    handle_fragment(fragment, parent, debug, state)
  end
  defp handle_frame(frame, parent, debug, state) do
    common_handle({:handle_frame, frame}, parent, debug, state)
  end

  defp common_handle({function, msg}, parent, debug, state) do
    case apply(state.module, function, [msg, state.module_state]) do
      {:ok, new_state} ->
        websocket_loop(parent, debug, %{state | module_state: new_state})
      {:reply, frame, new_state} ->
        with {:ok, binary_frame} <- WebSockex.Frame.encode_frame(frame),
             :ok <- WebSockex.Conn.socket_send(state.conn, binary_frame) do
          websocket_loop(parent, debug, %{state | module_state: new_state})
        else
          {:error, error} ->
            raise error
        end
      {:close, new_state} ->
        handle_close({:local, :normal}, parent, debug, %{state | module_state: new_state})
      {:close, {close_code, message}, new_state} ->
        handle_close({:local, close_code, message}, parent, debug, %{state | module_state: new_state})
      badreply ->
        raise %WebSockex.BadResponseError{module: state.module,
          function: function, args: [msg, state.module_state],
          response: badreply}
    end
  rescue
    exception ->
      terminate({exception, System.stacktrace}, parent, debug, state)
  end

  defp handle_close({:remote, _} = reason, parent, debug, state) do
    handle_remote_close(reason, parent, debug, state)
  end
  defp handle_close({:remote, _, _} = reason, parent, debug, state) do
    handle_remote_close(reason, parent, debug, state)
  end
  defp handle_close({:local, _} = reason, parent, debug, state) do
    handle_local_close(reason, parent, debug, state)
  end
  defp handle_close({:local, _, _} = reason, parent, debug, state) do
    handle_local_close(reason, parent, debug, state)
  end

  defp handle_disconnect(reason, parent, debug, state) do
    case apply(state.module, :handle_disconnect, [reason, state.module_state]) do
      {:ok, new_state} ->
        terminate(reason, parent, debug, %{state | module_state: new_state})
      {:reconnect, new_state} ->
        case open_connection(state.conn) do
          {:ok, conn} ->
            websocket_loop(parent, debug, %{state | conn: conn, module_state: new_state})
          {:error, term} ->
            raise term
        end
      badreply ->
        raise %WebSockex.BadResponseError{module: state.module,
          function: :handle_disconnect, args: [reason, state.module_state],
          response: badreply}
    end
  rescue
    exception ->
      terminate({exception, System.stacktrace}, parent, debug, state)
  end

  defp module_init(module, module_state, conn) do
    case apply(module, :init, [module_state, conn]) do
      {:ok, new_state} ->
        {:ok, new_state}
      badreply ->
        raise %WebSockex.BadResponseError{module: module, function: :init,
          args: [module_state, conn], response: badreply}
    end
  end

  defp terminate(reason, _parent, _debug, %{module: mod, module_state: mod_state}) do
    mod.terminate(reason, mod_state)
    case reason do
      {_, :normal} ->
        exit(:normal)
      {_, 1000, _} ->
        exit(:normal)
      _ ->
        exit(reason)
    end
  end

  defp handle_send(binary_frame, parent, debug, %{conn: conn} = state) do
    case WebSockex.Conn.socket_send(conn, binary_frame) do
      :ok ->
        websocket_loop(parent, debug, state)
      {:error, error} ->
        terminate(error, parent, debug, state)
    end
  end

  defp handle_fragment({:fragment, type, part}, parent, debug, %{fragment: nil} = state) do
    websocket_loop(parent, debug, %{state | fragment: {type, part}})
  end
  defp handle_fragment({:fragment, _, _}, parent, debug, state) do
    handle_close({:local, 1002, "Endpoint tried to start a fragment without finishing another"}, parent, debug, state)
  end
  defp handle_fragment({:continuation, _}, parent, debug, %{fragment: nil} = state) do
    handle_close({:local, 1002, "Endpoint sent a continuation frame without starting a fragment"}, parent, debug, state)
  end
  defp handle_fragment({:continuation, next}, parent, debug, %{fragment: {type, part}} = state) do
    websocket_loop(parent, debug, %{state | fragment: {type, <<part::binary, next::binary>>}})
  end
  defp handle_fragment({:finish, next}, parent, debug, %{fragment: {type, part}} = state) do
    handle_frame({type, <<part::binary, next::binary>>}, parent, debug, %{state | fragment: nil})
  end

  defp handle_remote_close(reason, parent, debug, state) do
    # If the socket is already closed then that's ok, but the spec says to send
    # the close frame back in response to receiving it.
    case send_close_frame(reason, state.conn) do
      :ok -> :ok
      {:error, %WebSockex.ConnError{original: :closed}} -> :ok
      {:error, error} ->
        raise error
    end

    new_conn = WebSockex.Conn.wait_for_tcp_close(state.conn)
    state = %{state | conn: new_conn}

    handle_disconnect(reason, parent, debug, state)
  end

  defp handle_local_close(reason, parent, debug, state) do
    with :ok <- WebSockex.Conn.set_active(state.conn, false),
         :ok <- send_close_frame(reason, state.conn),
         new_conn <- WebSockex.Conn.wait_for_tcp_close(state.conn) do
      handle_disconnect(reason, parent, debug, %{state | conn: new_conn})
    else
      {:error, error} ->
        raise error
    end
  end

  defp send_close_frame(reason, conn) do
    with {:ok, binary_frame} <- build_close_frame(reason),
    do: WebSockex.Conn.socket_send(conn, binary_frame)
  end

  defp build_close_frame({_, :normal}) do
    WebSockex.Frame.encode_frame(:close)
  end
  defp build_close_frame({_, code, msg}) do
    WebSockex.Frame.encode_frame({:close, code, msg})
  end
end
