class Apexyard < Formula
  desc "Create and manage ApexYard ops repositories"
  homepage "https://github.com/me2resh/apexyard"
  url "https://github.com/me2resh/apexyard/releases/download/__TAG__/apexyard-__TAG__.tar.gz"
  version "__VERSION__"
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
