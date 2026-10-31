defmodule ClothespinWeb.ChannelCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that interact with channels.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint ClothespinWeb.Endpoint

      # Import conveniences for testing with channels
      import Phoenix.ChannelTest

      defp build_socket(user_id, room_id, name) do
        %Phoenix.Socket{
          endpoint: @endpoint,
          assigns: %{user_id: user_id, room_id: room_id, user_name: name}
        }
      end
    end
  end

  setup tags do
    Clothespin.DataCase.setup_sandbox(tags)
    :ok
  end
end
