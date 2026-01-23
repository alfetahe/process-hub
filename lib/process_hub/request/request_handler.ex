defprotocol ProcessHub.Request.RequestHandler do
  def preprocess(request_handler, hub)
  def handle(request_handler, hub)
end
