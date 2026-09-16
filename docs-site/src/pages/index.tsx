import React from 'react';
import Link from '@docusaurus/Link';
import useDocusaurusContext from '@docusaurus/useDocusaurusContext';
import Layout from '@theme/Layout';

export default function Home() {
  const {siteConfig} = useDocusaurusContext();
  return (
    <Layout title={siteConfig.title} description="Blueforce fleet documentation">
      <main style={{padding: '4rem 2rem', textAlign: 'center'}}>
        <h1>{siteConfig.title}</h1>
        <p>{siteConfig.tagline}</p>
        <Link className="button button--primary button--lg" to="/MASTER-PLAN">
          Open docs
        </Link>
      </main>
    </Layout>
  );
}
