relationship between the beans. The only difference from previous exercises is the change in the INDI name element tac for the Address home interface:

<local-indi-name>AddressHomeLocal</local-indi-name>

Because the Home interface for the Address is local, the tag is <local-jndi-name> rather than <ndi-name>

the weblogic cmp-rdbms-jar.xml descriptor contains a number of new sections and elements

that will be added to the database, and the sections will wait until the next

exercise, but there are other changes to observe and examine.

the file contains a section mapping the the job for run

attributes from the job for run

table in addition to a new section related to

the automatic key generation for primary keys in this box

```xml

<weblogic-rdbms-bean>

  <ejb-name>AddressJDBC</ejb-name>

  <data-source-name>Titan-dataSource</data-source-name>

  <table-name>ADDRESS</table-name>

  <field-map>

    <cmp-field>id</cmp-field>

    <dbms-column>ID</dbms-column>

  </field-map>

  <field-map>

    <cmp-field>street</cmp-field>

    <dbms-column>STREET</dbms-column>

  </field-map>

  <field-map>

    <cmp-field>city</cmp-field>

    <dbms-column>CITY</dbms-column>

  </field-map>

  <field-map>

    <cmp-field>state</cmp-field>

    <dbms-column>STATE</dbms-column>

  </field-map>

  <field-map>

    <cmp-field>zip</cmp-field>

    <dbms-column>ZIP</dbms-column>

  </field-map>

  <!-- Automatically generate the value of ID in the database on

inserts using sequence table -->

  <automatic-key-generation>

    <generator-type>NAMED SEQUENCE TABLE</generator-type>

    <generator-name>ADDRESS SEQUENCE</generator-name>

    <key-cache-size>10</key-cache-size>

  </automatic-key-generation>

</weblogic-rdbms-bean>

```
