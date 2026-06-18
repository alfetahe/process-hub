Logger.configure(level: :warning)
# Drop known-benign log noise so real warnings still surface. See the module
# for the list of filtered messages.
Test.Helper.LoggerFilters.install()
ExUnit.start()
Test.Helper.TestNode.start_local_node()
