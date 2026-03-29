const { S3Client } = require('@aws-sdk/client-s3');

const BUCKET = process.env.S3_BUCKET || 'prismata-3d-models';
const REGION = process.env.AWS_REGION || 'us-east-1';

const s3 = new S3Client({ region: REGION });

module.exports = { s3, BUCKET, REGION };
