defprotocol ProcessHub.Request.CrossNodeRequest do
  def handle(request_handler, hub)
end
