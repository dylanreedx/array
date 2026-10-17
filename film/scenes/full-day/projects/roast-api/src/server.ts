import { createServer } from './http';
import { orders } from './orders/routes';

createServer({ port: 4000 }).use('/orders', orders).listen();
