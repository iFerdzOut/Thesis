// ignore_for_file: avoid_print

/// TrustedDomainsService
///
/// Comprehensive trusted domains list for Philippine users.
/// Covers: Government, Banks, E-wallets, Telcos, E-commerce,
/// Delivery, Healthcare, Education, International platforms.
class TrustedDomainsService {

  static const Set<String> _trustedDomains = {

    // ══════════════════════════════════════════════════════════════════
    // PHILIPPINE GOVERNMENT
    // ══════════════════════════════════════════════════════════════════
    'gov.ph',
    'senate.gov.ph',
    'congress.gov.ph',
    'judiciary.gov.ph',
    'sc.judiciary.gov.ph',

    // Executive offices
    'president.gov.ph',
    'op.gov.ph',
    'ovp.gov.ph',
    'pcoo.gov.ph',

    // Economic & Finance
    'dof.gov.ph',
    'bir.gov.ph',
    'boc.gov.ph',
    'bsp.gov.ph',
    'neda.gov.ph',
    'dti.gov.ph',
    'sec.gov.ph',
    'ic.gov.ph',
    'cda.gov.ph',
    'pse.com.ph',

    // Social services
    'dswd.gov.ph',
    'sss.gov.ph',
    'gsis.gov.ph',
    'philhealth.gov.ph',
    'pagibig.gov.ph',
    'hdmf.gov.ph',
    'dole.gov.ph',
    'owwa.gov.ph',
    'poea.gov.ph',
    'doh.gov.ph',
    'phic.gov.ph',

    // Infrastructure & Transport
    'dpwh.gov.ph',
    'dot.gov.ph',
    'dotc.gov.ph',
    'lto.gov.ph',
    'ltfrb.gov.ph',
    'marina.gov.ph',
    'caap.gov.ph',
    'naia.gov.ph',
    'miaa.gov.ph',

    // Interior & Justice
    'dilg.gov.ph',
    'pnp.gov.ph',
    'bjmp.gov.ph',
    'bucor.gov.ph',
    'doj.gov.ph',
    'nbi.gov.ph',
    'immigration.gov.ph',
    'doi.gov.ph',

    // Civil registration & ID
    'psa.gov.ph',
    'comelec.gov.ph',
    'philsys.gov.ph',

    // Education
    'deped.gov.ph',
    'ched.gov.ph',
    'tesda.gov.ph',
    'up.edu.ph',
    'dlsu.edu.ph',
    'ateneo.edu.ph',
    'ust.edu.ph',
    'admu.edu.ph',
    'feu.edu.ph',
    'pup.edu.ph',
    'tip.edu.ph',

    // Defense & Foreign Affairs
    'dfa.gov.ph',
    'dnd.gov.ph',
    'afp.mil.ph',
    'passport.gov.ph',

    // Environment & Agriculture
    'denr.gov.ph',
    'da.gov.ph',
    'bfar.gov.ph',
    'pagasa.dost.gov.ph',
    'dost.gov.ph',
    'phivolcs.dost.gov.ph',
    'ndrrmc.gov.ph',

    // Local Government
    'manila.gov.ph',
    'quezon-city.gov.ph',
    'makati.gov.ph',
    'taguig.gov.ph',
    'pasig.gov.ph',
    'cebu.gov.ph',
    'davao.gov.ph',

    // ══════════════════════════════════════════════════════════════════
    // PHILIPPINE BANKS
    // ══════════════════════════════════════════════════════════════════
    'bdo.com.ph',
    'bpi.com.ph',
    'metrobank.com.ph',
    'mbtc.com.ph',
    'landbank.com',
    'lbp.com.ph',
    'dbp.ph',
    'unionbankph.com',
    'unionbank.com.ph',
    'rcbc.com',
    'rcbcsavings.com',
    'securitybank.com',
    'chinabank.ph',
    'eastwestbanker.com',
    'psbank.com.ph',
    'maybank.com.ph',
    'pnb.com.ph',
    'alliedbank.com.ph',
    'aub.com.ph',
    'bankofcommerce.com.ph',
    'cimbbank.com.ph',
    'gotymeb.com',
    'bnkd.ph',
    'tonik.com.ph',
    'overseas-filipino-bank.com',
    'seabank.com.ph',
    'robinsonsbank.com.ph',
    'ibank.com.ph',
    'starpay.com.ph',
    'ofw-bank.com.ph',

    // ══════════════════════════════════════════════════════════════════
    // E-WALLETS & FINTECH
    // ══════════════════════════════════════════════════════════════════
    'gcash.com',
    'maya.ph',
    'paymaya.com',
    'coins.ph',
    'grabpay.com',
    'grabpay.com.ph',
    'shopeepay.com.ph',
    'lazwallet.com',
    'paypal.com',
    'wise.com',
    'remitly.com',
    'westernunion.com',
    'moneygram.com',
    'instapay.ph',
    'pesonet.ph',
    'phzeus.com',

    // ══════════════════════════════════════════════════════════════════
    // PHILIPPINE TELCOS
    // ══════════════════════════════════════════════════════════════════
    'globe.com.ph',
    'globeone.com.ph',
    'tnt.com.ph',
    'smart.com.ph',
    'smartcommunications.com.ph',
    'sun.net.ph',
    'dito.ph',
    'ditotelecommunity.com',
    'pldt.com',
    'pldthome.com',
    'convergeict.com',
    'skycable.com',
    'cignal.tv',

    // ══════════════════════════════════════════════════════════════════
    // E-COMMERCE & DELIVERY
    // ══════════════════════════════════════════════════════════════════
    'shopee.ph',
    'lazada.com.ph',
    'zalora.com.ph',
    'carousell.ph',
    'metrodeal.com',
    'ensogo.com.ph',
    'ebay.ph',
    'amazon.com',
    'aliexpress.com',
    'temu.com',
    'shein.com',

    // Delivery & logistics
    'jntexpress.com.ph',
    'ninjavan.com',
    'lbcexpress.com',
    'lbc.com.ph',
    'xend.com.ph',
    'airspeed.com.ph',
    '2go.com.ph',
    'grab.com',
    'foodpanda.com.ph',
    'angkas.com',
    'joyride.com.ph',
    'mysuki.ph',

    // ══════════════════════════════════════════════════════════════════
    // HEALTHCARE
    // ══════════════════════════════════════════════════════════════════
    'healthway.com.ph',
    'makatimedcenter.com',
    'stlukesmedicalcenter.com',
    'themedicalcity.com',
    'asianhospital.com',
    'uermmc.edu.ph',
    'ncmh.gov.ph',
    'ritm.gov.ph',
    'pcso.gov.ph',
    'rose-pharmacy.com',
    'generika.com.ph',
    'southstardrugph.com',
    'mercury-drug.com',
    'mercurydrug.com',
    'watsons.com.ph',

    // ══════════════════════════════════════════════════════════════════
    // UTILITIES
    // ══════════════════════════════════════════════════════════════════
    'meralco.com.ph',
    'maynilad.com.ph',
    'mwss.gov.ph',
    'mwd.com.ph',
    'petron.com',
    'shellph.com',
    'caltex.com.ph',
    'phoenix-fuels.com',
    'cleanfuel.com.ph',
    'pilipinasshell.com',

    // ══════════════════════════════════════════════════════════════════
    // NEWS & MEDIA
    // ══════════════════════════════════════════════════════════════════
    'rappler.com',
    'inquirer.net',
    'philstar.com',
    'abs-cbn.com',
    'gmanetwork.com',
    'gma.com.ph',
    'manilabulletin.com',
    'manilatimes.net',
    'sunstar.com.ph',
    'pna.gov.ph',
    'pia.gov.ph',
    'pcij.org',
    'businessworld.com.ph',
    'businessmirror.com.ph',
    'cnnphilippines.com',
    'interaksyon.com',
    'mb.com.ph',
    'malaya.com.ph',

    // ══════════════════════════════════════════════════════════════════
    // INTERNATIONAL — SOCIAL MEDIA
    // ══════════════════════════════════════════════════════════════════
    'facebook.com',
    'fb.com',
    'messenger.com',
    'instagram.com',
    'twitter.com',
    'x.com',
    'linkedin.com',
    'tiktok.com',
    'youtube.com',
    'youtu.be',
    'snapchat.com',
    'pinterest.com',
    'reddit.com',
    'discord.com',
    'telegram.org',
    't.me',
    'whatsapp.com',
    'signal.org',
    'viber.com',
    'skype.com',
    'zoom.us',
    'meet.google.com',
    'teams.microsoft.com',

    // ══════════════════════════════════════════════════════════════════
    // INTERNATIONAL — TECH & EMAIL
    // ══════════════════════════════════════════════════════════════════
    'google.com',
    'gmail.com',
    'accounts.google.com',
    'drive.google.com',
    'docs.google.com',
    'forms.google.com',
    'play.google.com',
    'microsoft.com',
    'office.com',
    'outlook.com',
    'live.com',
    'hotmail.com',
    'apple.com',
    'icloud.com',
    'yahoo.com',
    'ymail.com',
    'proton.me',
    'protonmail.com',
    'dropbox.com',
    'onedrive.com',
    'box.com',
    'github.com',
    'gitlab.com',
    'stackoverflow.com',
    'medium.com',
    'wordpress.com',
    'blogspot.com',
    'wikipedia.org',

    // ══════════════════════════════════════════════════════════════════
    // INTERNATIONAL — TRAVEL & TRANSPORT
    // ══════════════════════════════════════════════════════════════════
    'airasia.com',
    'cebuair.com',
    'philippineairlines.com',
    'pal.com.ph',
    'skyjet.com.ph',
    'sunlight-air.com.ph',
    'booking.com',
    'agoda.com',
    'airbnb.com',
    'tripadvisor.com',
    'klook.com',
    'traveloka.com',

    // ══════════════════════════════════════════════════════════════════
    // INTERNATIONAL — STREAMING & ENTERTAINMENT
    // ══════════════════════════════════════════════════════════════════
    'netflix.com',
    'spotify.com',
    'disneyplus.com',
    'hbomax.com',
    'viu.com',
    'wetv.vip',
    'vivamax.net',

    // ══════════════════════════════════════════════════════════════════
    // CYBERSECURITY & SAFETY
    // ══════════════════════════════════════════════════════════════════
    'dict.gov.ph',
    'cicc.gov.ph',
    'pnp-acg.com',
    'cybercrime.gov.ph',
    'dicts.gov.ph',
    'virustotal.com',
    'haveibeenpwned.com',
  };

  /// Extracts all URLs from a message
  static List<String> extractUrls(String message) {
    final urlPattern = RegExp(
      r'(https?://[^\s]+|www\.[^\s]+|[a-zA-Z0-9\-]+\.(com|net|org|ph|gov|edu|io|xyz|ml|info|tv|me)[^\s]*)',
      caseSensitive: false,
    );
    return urlPattern
        .allMatches(message)
        .map((m) => m.group(0)!)
        .toList();
  }

  /// Extracts the root domain from a URL
  static String extractDomain(String url) {
    try {
      String cleaned = url
          .replaceAll('hxxps[://]', 'https://')
          .replaceAll('hxxp[://]', 'http://')
          .replaceAll('[.]', '.');

      if (!cleaned.startsWith('http')) {
        cleaned = 'https://$cleaned';
      }

      final uri = Uri.parse(cleaned);
      final host = uri.host.toLowerCase();
      return host.startsWith('www.') ? host.substring(4) : host;
    } catch (e) {
      return url.toLowerCase();
    }
  }

  /// Returns true if ALL URLs trusted, false if ANY unknown, null if no URLs
  static bool? checkMessage(String message) {
    final urls = extractUrls(message);
    if (urls.isEmpty) return null;

    for (final url in urls) {
      final domain = extractDomain(url);
      final isTrusted = _isTrustedDomain(domain);
      print('[TrustedDomains] $domain → trusted: $isTrusted');
      if (!isTrusted) return false;
    }
    return true;
  }

  /// Subdomain-aware trusted domain check
  static bool _isTrustedDomain(String domain) {
    if (_trustedDomains.contains(domain)) return true;
    for (final trusted in _trustedDomains) {
      if (domain.endsWith('.$trusted') || domain == trusted) return true;
    }
    return false;
  }

  static bool isUrlTrusted(String url) {
    return _isTrustedDomain(extractDomain(url));
  }

  static List<Map<String, dynamic>> analyzeUrls(String message) {
    return extractUrls(message).map((url) {
      final domain = extractDomain(url);
      return {
        'url': url,
        'domain': domain,
        'trusted': _isTrustedDomain(domain),
      };
    }).toList();
  }
}