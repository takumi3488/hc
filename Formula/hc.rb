class Hc < Formula
  desc "Herdr lifecycle-aware command wrapper"
  homepage "https://github.com/takumi3488/hc"
  version "0.1.1"

  on_macos do
    on_arm do
      url "https://github.com/takumi3488/hc/releases/download/v0.1.1/hc-aarch64-macos-none.tar.gz"
      sha256 "4c1d4e9511ff917a5aefc289e058cd8806fe93cd6da12a09b61c508d6d92dd31"
    end
    on_intel do
      url "https://github.com/takumi3488/hc/releases/download/v0.1.1/hc-x86_64-macos-none.tar.gz"
      sha256 "5341bb61dcff2f3ddecef315629a3448b3004ef86be65fc0366bdd76af34ad4b"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/takumi3488/hc/releases/download/v0.1.1/hc-aarch64-linux-musl.tar.gz"
      sha256 "d737c91889bee4b83af30050bb134dcdcbc8ebf1705d8139b93192cfc9b4f802"
    end
    on_intel do
      url "https://github.com/takumi3488/hc/releases/download/v0.1.1/hc-x86_64-linux-musl.tar.gz"
      sha256 "4b2aab560d9e26f6bad5dc17f849fb970012531b7c578c801229997b54453dc6"
    end
  end

  def install
    bin.install "hc"
  end

  test do
    ENV["HERDR_ENV"] = "0"
    assert_equal "hc-homebrew-smoke
", shell_output("#{bin}/hc -- /bin/echo hc-homebrew-smoke")
    assert_empty shell_output("#{bin}/hc -- /bin/sh -c 'exit 37'", 37)
  end
end
