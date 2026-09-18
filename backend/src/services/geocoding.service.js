import { AppError } from '../utils/errors.js';

/**
 * Forward geocoding via OpenStreetMap's Nominatim — free, no API key. Kept
 * isolated behind this one method so a paid provider (e.g. Google Maps, once
 * a real GOOGLE_MAPS_KEY exists) can replace the implementation later without
 * touching any caller.
 *
 * Nominatim's usage policy requires a real identifying User-Agent and caps
 * usage at ~1 req/sec — fine for interactive address entry, not for bulk use.
 */
export const GeocodingService = {
  async forward({ line1, city, region, postalCode }) {
    const q = `${line1}, ${city}, ${region} ${postalCode}, USA`;
    const res = await fetch(
      `https://nominatim.openstreetmap.org/search?format=json&limit=1&q=${encodeURIComponent(q)}`,
      { headers: { 'User-Agent': 'SparkleCleaning/1.0 (support@sparkle.app)' } },
    );
    const [hit] = await res.json();
    if (!hit) {
      throw AppError.badRequest('ADDRESS_NOT_FOUND', "We couldn't find that address. Check it and try again.");
    }
    return { lat: Number(hit.lat), lng: Number(hit.lon) };
  },
};
