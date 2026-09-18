import { PropertyService } from '../../services/property.service.js';

export const PropertyController = {
  async list(req, res, next) {
    try { res.json({ properties: await PropertyService.list(req.user.id) }); }
    catch (err) { next(err); }
  },

  async create(req, res, next) {
    try { res.status(201).json(await PropertyService.create({ customerId: req.user.id, ...req.body })); }
    catch (err) { next(err); }
  },
};
