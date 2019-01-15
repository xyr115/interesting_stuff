class Bro < Formula
  desc "Network security monitor"
  homepage "https://www.bro.org"
  url "https://www.bro.org/downloads/bro-2.5.5.tar.gz"
  sha256 "18f2aeb10b4d935d85c115a1e4a93464b9750be19b34997cf6196b29118e73cf"
  head "https://github.com/bro/bro.git"

  depends_on "cmake" => :build
  depends_on "swig" => :build
  depends_on "openssl"
  depends_on "geoip" => :recommended

  def install
    system "./configure", "--prefix=#{prefix}",
                          "--with-openssl=#{Formula["openssl"].opt_prefix}",
                          "--localstatedir=#{var}",
                          "--conf-files-dir=#{etc}"
    system "make", "install"
  end

  test do
    system "#{bin}/bro", "--version"
  end
end
