import { query, withTransaction } from '../db/pool.js';
import { GeocodingService } from './geocoding.service.js';

export const PropertyService = {
  async list(customerId) {
    const { rows } = await query(
      `SELECT p.id, p.bedrooms, p.bathrooms, p.square_feet, p.has_pets,
              a.id AS address_id, a.line1, a.line2, a.city, a.region, a.postal_code, a.access_notes
         FROM properties p
         JOIN addresses a ON a.id = p.address_id
        WHERE p.customer_id = $1 AND a.deleted_at IS NULL
        ORDER BY p.created_at DESC`,
      [customerId],
    );
    return rows;
  },

  // Geocode before ever touching the database — a bad address should never
  // produce a half-written row.
  async create({ customerId, line1, line2, city, region, postal_code, access_notes }) {
    const { lat, lng } = await GeocodingService.forward({ line1, city, region, postalCode: postal_code });

    return withTransaction(async (client) => {
      const { rows: [address] } = await client.query(
        `INSERT INTO addresses (user_id, label, line1, line2, city, region, postal_code, location, access_notes)
         VALUES ($1, 'Home', $2, $3, $4, $5, $6, ST_SetSRID(ST_MakePoint($7, $8), 4326), $9)
         RETURNING id, line1, line2, city, region, postal_code, access_notes`,
        [customerId, line1, line2 ?? null, city, region, postal_code, lng, lat, access_notes ?? null],
      );
      const { rows: [property] } = await client.query(
        `INSERT INTO properties (customer_id, address_id)
         VALUES ($1, $2)
         RETURNING id, bedrooms, bathrooms, square_feet, has_pets`,
        [customerId, address.id],
      );
      return { ...property, address_id: address.id, line1: address.line1, line2: address.line2,
        city: address.city, region: address.region, postal_code: address.postal_code,
        access_notes: address.access_notes };
    });
  },
};
