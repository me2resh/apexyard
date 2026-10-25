class Apexyard < Formula
  desc "Create and manage ApexYard ops repositories"
  homepage "https://github.com/me2resh/apexyard"
  url "https://github.com/me2resh/apexyard/releases/download/v0.1.0/apexyard-v0.1.0.tar.gz"
  version "0.1.0"
  sha256 "__SHA256__"
  license "MIT"

  def install
    libexec.install Dir["bin/*"]
    bin.write_exec_script libexec/"apexyard"
  end

  test do
    assert_match "Usage: apexyard", shell_output("#{bin}/apexyard --help")
  end
end
