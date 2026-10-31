defmodule ClothespinWeb.Presence do
  @moduledoc """
  Tracks browser presence on room topics.
  """

  use Phoenix.Presence, otp_app: :clothespin, pubsub_server: Clothespin.PubSub
end
