class Apexyard < Formula
  desc "Create and manage ApexYard ops repositories"
  homepage "https://github.com/me2resh/apexyard"
  url "https://github.com/me2resh/apexyard/releases/download/__TAG__/apexyard-__TAG__.tar.gz"
  version "__VERSION__"
  sha256 "__SHA256__"
  license "MIT"

  depends_on "jq"
  depends_on "gh"

  def install
    libexec.install "bin", ".claude"
    bin.write_exec_script libexec/"bin/apexyard"
  end

  test do
    assert_match "Usage: apexyard", shell_output("#{bin}/apexyard --help")
  end
end
