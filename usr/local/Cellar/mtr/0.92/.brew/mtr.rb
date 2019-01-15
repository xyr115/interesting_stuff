class Mtr < Formula
  desc "'traceroute' and 'ping' in a single tool"
  homepage "https://www.bitwizard.nl/mtr/"
  url "https://github.com/traviscross/mtr/archive/v0.92.tar.gz"
  sha256 "568a52911a8933496e60c88ac6fea12379469d7943feb9223f4337903e4bc164"
  head "https://github.com/traviscross/mtr.git"

  depends_on "automake" => :build
  depends_on "autoconf" => :build
  depends_on "pkg-config" => :build
  depends_on "gtk+" => :optional
  depends_on "glib" => :optional

  def install
    # We need to add this because nameserver8_compat.h has been removed in Snow Leopard
    ENV["LIBS"] = "-lresolv"
    args = %W[
      --disable-dependency-tracking
      --prefix=#{prefix}
    ]
    args << "--without-gtk" if build.without? "gtk+"
    args << "--without-glib" if build.without? "glib"
    system "./bootstrap.sh"
    system "./configure", *args
    system "make", "install"
  end

  def caveats; <<-EOS.undent
    mtr requires root privileges so you will need to run `sudo mtr`.
    You should be certain that you trust any software you grant root privileges.
    EOS
  end

  test do
    system sbin/"mtr", "--help"
  end
end
